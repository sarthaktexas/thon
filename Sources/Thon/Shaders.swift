let metalSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewSize;
    float2 center;
    float2 imgSize;
    float2 levelSize;
    float zoom;
    float lo;
    float hi;
    float gamma;
    int invert;
    int level;
    int nearest;
    int pad;
};

struct VOut { float4 position [[position]]; };

vertex VOut vs_main(uint vid [[vertex_id]]) {
    float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    VOut o; o.position = float4(p, 0, 1); return o;
}

fragment float4 fs_main(VOut in [[stage_in]],
                        texture2d<float, access::read> tex [[texture(0)]],
                        constant Uniforms& u [[buffer(0)]]) {
    float2 img = (in.position.xy - u.viewSize * 0.5) / u.zoom + u.center;
    if (img.x < 0.0 || img.y < 0.0 || img.x >= u.imgSize.x || img.y >= u.imgSize.y) {
        // checker-free dark surround
        return float4(0.075, 0.078, 0.086, 1.0);
    }
    float2 lp = img / float(1 << u.level);
    int2 hiIdx = int2(u.levelSize) - 1;
    float v;
    if (u.nearest != 0) {
        int2 c = clamp(int2(floor(lp)), int2(0), hiIdx);
        v = tex.read(uint2(c)).r;
    } else {
        float2 q = lp - 0.5;
        float2 f = fract(q);
        int2 i0 = int2(floor(q));
        int2 a = clamp(i0, int2(0), hiIdx);
        int2 b = clamp(i0 + 1, int2(0), hiIdx);
        float v00 = tex.read(uint2(uint(a.x), uint(a.y))).r;
        float v10 = tex.read(uint2(uint(b.x), uint(a.y))).r;
        float v01 = tex.read(uint2(uint(a.x), uint(b.y))).r;
        float v11 = tex.read(uint2(uint(b.x), uint(b.y))).r;
        v = mix(mix(v00, v10, f.x), mix(v01, v11, f.x), f.y);
    }
    float t = clamp((v - u.lo) / max(u.hi - u.lo, 1e-12), 0.0, 1.0);
    t = pow(t, u.gamma);
    if (u.invert != 0) t = 1.0 - t;
    return float4(t, t, t, 1.0);
}

kernel void downsample2x(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    uint2 mx = uint2(src.get_width() - 1, src.get_height() - 1);
    uint2 b = gid * 2;
    float s = src.read(min(b, mx)).r + src.read(min(b + uint2(1, 0), mx)).r
            + src.read(min(b + uint2(0, 1), mx)).r + src.read(min(b + uint2(1, 1), mx)).r;
    dst.write(float4(s * 0.25), gid);
}

kernel void gauss_h(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float* w [[buffer(0)]],
                    constant int& radius [[buffer(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    int W = int(src.get_width());
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float s = 0.0;
    for (int k = -radius; k <= radius; ++k) {
        int x = clamp(int(gid.x) + k, 0, W - 1);
        s += w[abs(k)] * src.read(uint2(uint(x), gid.y)).r;
    }
    dst.write(float4(s), gid);
}

kernel void gauss_v(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float* w [[buffer(0)]],
                    constant int& radius [[buffer(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    int H = int(src.get_height());
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float s = 0.0;
    for (int k = -radius; k <= radius; ++k) {
        int y = clamp(int(gid.y) + k, 0, H - 1);
        s += w[abs(k)] * src.read(uint2(gid.x, uint(y))).r;
    }
    dst.write(float4(s), gid);
}

// out = a - bilinear_upsample(bg) + offset      (background flattening)
kernel void flatten(texture2d<float, access::read> a [[texture(0)]],
                    texture2d<float, access::read> bg [[texture(1)]],
                    texture2d<float, access::write> dst [[texture(2)]],
                    constant float& invScale [[buffer(0)]],
                    constant float& offset [[buffer(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 q = (float2(gid) + 0.5) * invScale - 0.5;
    int2 hiIdx = int2(int(bg.get_width()), int(bg.get_height())) - 1;
    float2 f = fract(q);
    int2 i0 = int2(floor(q));
    int2 p = clamp(i0, int2(0), hiIdx);
    int2 r = clamp(i0 + 1, int2(0), hiIdx);
    float b = mix(mix(bg.read(uint2(uint(p.x), uint(p.y))).r, bg.read(uint2(uint(r.x), uint(p.y))).r, f.x),
                  mix(bg.read(uint2(uint(p.x), uint(r.y))).r, bg.read(uint2(uint(r.x), uint(r.y))).r, f.x), f.y);
    dst.write(float4(a.read(gid).r - b + offset), gid);
}
"""
