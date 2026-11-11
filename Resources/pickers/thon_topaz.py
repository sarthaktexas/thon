#!/usr/bin/env python3
"""Thon external picker: Topaz (pretrained resnet16_u64) on one micrograph.

Prints JSON [{"x":..,"y":..,"score":..}, ...] in native pixel coordinates (origin top-left,
pixel centre = integer), best score first. score = Topaz log-likelihood ratio minus the cutoff, so it is >= 0. Run with the Python of an environment that has
`topaz-em` and `mrcfile` installed.

  thon_topaz.py MIC.mrc --diameter-px 34 [--scale N] [--threshold -1] [--invert] [--max 400] [--threads 2]
"""
import argparse, json, os, subprocess, sys, tempfile, shutil

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mic")
    ap.add_argument("--diameter-px", type=float, required=True, help="particle diameter in native pixels")
    ap.add_argument("--scale", type=int, default=0, help="downscale factor; 0 = choose so the particle radius is about 4 px (CPU time grows about 4x per halving)")
    ap.add_argument("--threshold", type=float, default=-1.0, help="log-likelihood-ratio cutoff (Topaz default -6; -1 keeps roughly p >= 0.27)")
    ap.add_argument("--invert", action="store_true", help="flip contrast before picking")
    ap.add_argument("--max", type=int, default=400)
    ap.add_argument("--threads", type=int, default=2)
    ap.add_argument("--model", default="resnet16_u64")
    a = ap.parse_args()

    import numpy as np, mrcfile
    topaz = os.path.join(os.path.dirname(sys.executable), "topaz")
    if not os.path.exists(topaz):
        topaz = shutil.which("topaz") or sys.exit("topaz executable not found next to " + sys.executable)

    env = dict(os.environ, OMP_NUM_THREADS=str(a.threads), MKL_NUM_THREADS=str(a.threads),
               OPENBLAS_NUM_THREADS=str(a.threads), PYTHONDONTWRITEBYTECODE="1")
    radius = a.diameter_px / 2
    s = a.scale if a.scale > 0 else max(1, int(round(radius / 4)))
    r_ds = max(2, int(round(radius / s)))

    with tempfile.TemporaryDirectory(prefix="thon_topaz_") as w:
        src = a.mic
        if a.invert:
            with mrcfile.open(a.mic, permissive=True) as m:
                d = np.asarray(m.data, dtype=np.float32)
            if d.ndim == 3: d = d[0]
            src = os.path.join(w, "inv.mrc")
            with mrcfile.new(src) as o: o.set_data(-d)
        ds = os.path.join(w, "ds"); os.makedirs(ds)
        def run(cmd):
            p = subprocess.run(cmd, env=env, capture_output=True, text=True)
            if p.returncode != 0:
                sys.exit("topaz failed: " + (p.stderr or p.stdout)[-400:])
        run([topaz, "preprocess", "-s", str(s), "-d", "-1", "-t", "1", "-o", ds, src])
        out = os.path.join(w, "picks.txt")
        run([topaz, "extract", "-r", str(r_ds), "-x", str(s), "-m", a.model, "-d", "-1",
             "-t", str(a.threshold), "-j", str(a.threads), "-o", out, os.path.join(ds, os.path.basename(src))])
        rows = []
        with open(out) as f:
            for line in f:
                t = line.split()
                if len(t) < 4 or t[0] == "image_name": continue
                try: rows.append({"x": float(t[1]), "y": float(t[2]), "score": float(t[3]) - a.threshold})
                except ValueError: pass
    rows.sort(key=lambda r: -r["score"])
    json.dump(rows[:a.max], sys.stdout)
    sys.stderr.write("topaz: %d picks (scale %d, radius %d px downscaled)\n" % (len(rows), s, r_ds))

if __name__ == "__main__":
    main()
