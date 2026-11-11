#!/usr/bin/env python3
"""Thon external picker: CryoSegNet (attention U-Net + Segment Anything) on one micrograph.

Prints JSON [{"x":..,"y":..,"score":..}, ...] in native pixel coordinates (origin top-left, y down,
numpy/mrcfile row order), best score first. score = (SAM predicted IoU - 0.94) x 100, i.e. 0 to 6. Run with the Python of an environment that has torch,
segment-anything, opencv-python, mrcfile, scipy (see requirements-macos.txt in the CryoSegNet fork)
and give it the fork's directory (--repo) and the folder that holds the pretrained weights (--weights).

  thon_cryosegnet.py MIC.mrc --repo DIR --weights DIR [--diameter-px 34] [--tile 0]

--tile 0 reproduces the stock pipeline: the whole micrograph is resized to 1024 x 1024 and only boxes
near the modal box size are kept. --tile N cuts N x N pixel tiles (native pixels, 25 % overlap), resizes
each to 1024 and keeps boxes whose size matches --diameter-px, which is the way to try small particles.
"""
import argparse, json, os, sys

def select_boxes(masks, scale_x, scale_y, target_diam_px=None, iou_min=0.94, tol=0.4):
    """masks: SAM output dicts (bbox = x, y, w, h in the 1024 px frame, predicted_iou).
    Returns [(cx, cy, iou)] in native pixels of the processed frame (scale_* = native / 1024)."""
    import statistics
    good = [m for m in masks if m["predicted_iou"] > iou_min]
    if not good:
        return []
    if target_diam_px:
        # box sizes are compared in native pixels
        out = []
        for m in good:
            x, y, w, h = m["bbox"]
            d = (w * scale_x * h * scale_y) ** 0.5
            if abs(d - target_diam_px) <= tol * target_diam_px:
                out.append(((x + w / 2) * scale_x, (y + h / 2) * scale_y, float(m["predicted_iou"])))
        return out
    wm = statistics.mode([m["bbox"][2] for m in good]); hm = statistics.mode([m["bbox"][3] for m in good])
    d = ((wm * scale_x) ** 2 + (hm * scale_y) ** 2) ** 0.5
    th = int(d // 2) * 0.2
    out = []
    for m in good:
        x, y, w, h = m["bbox"]
        if wm - th / 3 < w < wm + th and hm - th / 3 < h < hm + th:
            out.append(((x + w / 2) * scale_x, (y + h / 2) * scale_y, float(m["predicted_iou"])))
    return out

def nms(pts, min_dist):
    pts = sorted(pts, key=lambda p: -p[2]); keep = []
    for p in pts:
        if all((p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2 >= min_dist ** 2 for q in keep):
            keep.append(p)
    return keep

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mic"); ap.add_argument("--repo", required=True); ap.add_argument("--weights", required=True)
    ap.add_argument("--diameter-px", type=float, default=0.0)
    ap.add_argument("--tile", type=int, default=0)
    ap.add_argument("--device", default="auto", help="auto (CUDA > MPS > CPU), mps or cpu")
    ap.add_argument("--max", type=int, default=400)
    ap.add_argument("--threads", type=int, default=2)
    a = ap.parse_args()

    os.environ.setdefault("OMP_NUM_THREADS", str(a.threads)); os.environ.setdefault("MKL_NUM_THREADS", str(a.threads))
    sys.path.insert(0, os.path.abspath(a.repo)); sys.dont_write_bytecode = True
    import numpy as np, cv2, mrcfile, torch
    import mps_compat                      # must come first (MPS fallback + SAM float32 patch)
    torch.set_num_threads(a.threads)
    from models.model_5_layers import UNET
    from utils import denoise as dn
    from segment_anything import SamAutomaticMaskGenerator

    dev = mps_compat.best_device() if a.device == "auto" else a.device
    ck = lambda n: os.path.join(a.weights, n)
    for n in ("cryosegnet.pth", "sam_vit_h_4b8939.pth"):
        if not os.path.exists(ck(n)): sys.exit("missing weight file " + ck(n))
    model = UNET().to(device=dev); model.load_state_dict(mps_compat.load_checkpoint(ck("cryosegnet.pth"))); model.eval()
    sam = mps_compat.build_sam("vit_h", ck("sam_vit_h_4b8939.pth"), dev)
    gen = SamAutomaticMaskGenerator(sam)

    def transform(im):
        lo, hi = im.min(), im.max()
        return im if hi == 0 else ((im - lo) / (hi - lo) * 255).astype("uint8")

    # same pre-processing as the fork's denoise(): transpose + rot90 flips the rows (y -> H-1-y)
    raw = np.asarray(mrcfile.read(a.mic), dtype=np.float32)
    if raw.ndim == 3: raw = raw[0]
    H, W = raw.shape
    img = np.rot90(raw.T)
    img = dn.standard_scaler(np.array(img)); img = dn.contrast_enhancement(img)
    img = dn.wiener_filter(img, dn.kernel, K=30); cl = dn.clahe(img); img = dn.guided_filter(cl, img)

    def pick(tile_img, target):
        h, w = tile_img.shape
        x = cv2.resize(tile_img, (1024, 1024))
        t = (torch.from_numpy(x).unsqueeze(0).float() / 255.0).to(dev).unsqueeze(0)
        with torch.no_grad():
            m = torch.sigmoid(model(t)).cpu().numpy().reshape(1024, 1024)
        m = np.rot90(m, k=3).T
        sam_in = np.repeat(transform(m)[:, :, None], 3, axis=-1)
        masks = gen.generate(sam_in)
        return select_boxes(masks, w / 1024.0, h / 1024.0, target)

    pts = []
    if a.tile <= 0:
        pts = pick(img, None)
        mind = 0.5 * (a.diameter_px or 0)
    else:
        if a.diameter_px <= 0: sys.exit("--tile needs --diameter-px")
        n = min(a.tile, W, H); step = max(1, int(n * 0.75))
        xs = sorted(set(list(range(0, max(W - n, 0) + 1, step)) + [max(W - n, 0)]))
        ys = sorted(set(list(range(0, max(H - n, 0) + 1, step)) + [max(H - n, 0)]))
        for y0 in ys:
            for x0 in xs:
                for cx, cy, s in pick(img[y0:y0 + n, x0:x0 + n], a.diameter_px):
                    pts.append((cx + x0, cy + y0, s))
        mind = 0.6 * a.diameter_px
    pts = nms(pts, mind) if mind else pts
    # back to the micrograph's own row order: y_array = H - 1 - y_flipped
    out = [{"x": round(x, 2), "y": round(H - 1 - y, 2), "score": round((s - 0.94) * 100, 3)} for x, y, s in pts][:a.max]
    json.dump(out, sys.stdout)
    sys.stderr.write("cryosegnet: %d picks on %s (tile %d)\n" % (len(out), dev, a.tile))

if __name__ == "__main__":
    main()
