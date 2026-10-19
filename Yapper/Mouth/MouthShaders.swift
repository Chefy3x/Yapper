import Foundation

/// The Loud Mouth's Metal shaders, compiled when the renderer starts (a fraction of a second, once)
/// so building Yapper doesn't need Xcode's separate Metal toolchain.
///
/// They match tools/mouth/build_mouth.py: the lips and hidden skin are bent by the bones on the GPU
/// (Blender's armature: weights normalised by their total) with normals rebuilt from the bent
/// faces; surfaces are flat colour or matte cel bands from one sun plus the world's faint light, with
/// the lips' darker inner band and crease strokes in (s, t); the ink outline is a pushed-out
/// back-face shell; holdout skin leaves the pixel clear.
enum MouthShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

// ---------- skinning ----------

kernel void mouth_skin(uint i [[thread_position_in_grid]],
                       const device float3 *rest [[buffer(0)]],
                       const device uint *start [[buffer(1)]],
                       const device ushort *bone [[buffer(2)]],
                       const device float *value [[buffer(3)]],
                       constant float4x4 *bones [[buffer(4)]],
                       device float3 *out [[buffer(5)]],
                       constant uint &count [[buffer(6)]]) {
    if (i >= count) return;
    float4 p = float4(rest[i], 1);
    float4 sum = 0;
    float total = 0;
    for (uint k = start[i]; k < start[i + 1]; k++) {
        float w = value[k];
        sum += w * (bones[bone[k]] * p);
        total += w;
    }
    out[i] = total > 1e-4 ? sum.xyz / total : rest[i];
}

// Smooth vertex normals weighted by each corner's angle, as Blender computes them. `corners` lists,
// per vertex, the triangle corners it sits on (triangle * 3 + corner).
kernel void mouth_normals(uint i [[thread_position_in_grid]],
                          const device float3 *p [[buffer(0)]],
                          const device uint *index [[buffer(1)]],
                          const device uint *start [[buffer(2)]],
                          const device uint *corners [[buffer(3)]],
                          device float3 *out [[buffer(4)]],
                          constant uint &count [[buffer(5)]]) {
    if (i >= count) return;
    float3 n = 0;
    for (uint k = start[i]; k < start[i + 1]; k++) {
        uint t = corners[k] / 3, j = corners[k] % 3;
        float3 a = p[index[3 * t]], b = p[index[3 * t + 1]], c = p[index[3 * t + 2]];
        float3 f = cross(b - a, c - a);
        float len = length(f);
        if (len < 1e-12) continue;
        float3 e1 = j == 0 ? b - a : (j == 1 ? a - b : a - c);
        float3 e2 = j == 0 ? c - a : (j == 1 ? c - b : b - c);
        float d = dot(e1, e2) / max(1e-12, length(e1) * length(e2));
        n += (f / len) * acos(clamp(d, -1.0, 1.0));
    }
    float l = length(n);
    out[i] = l > 1e-12 ? n / l : float3(0, 0, 1);
}

// ---------- drawing ----------

struct MouthDraw {
    float4x4 model;      // rig space -> world (Blender axes)
    float4x4 viewProj;   // world -> clip (orthographic)
    float4 light;        // towards the sun, world
    float4 misc;         // x outline push, y diffuse (albedo / pi), z world light
};

struct MouthMaterial {
    float4 params;       // x kind (0 flat, 1 cel, 2 holdout), y band count, z stroke count, w inner band t
    float4 bandAt;       // brightness each cel band starts at
    float4 bandColor[4];
    float4 bandTint;     // xyz inner band tint, w stroke width
    float4 strokes[4];   // u0, v0, v1, bend
    float4 strokeColor;
    float4 color;        // flat colour
};

struct MouthOut {
    float4 position [[position]];
    float3 normal;
    float2 uv;
};

vertex MouthOut mouth_vertex(uint vid [[vertex_id]],
                             const device float3 *position [[buffer(0)]],
                             const device float3 *normal [[buffer(1)]],
                             const device float3 *hull [[buffer(2)]],
                             const device float2 *uv [[buffer(3)]],
                             const device float *ink [[buffer(4)]],
                             constant MouthDraw &draw [[buffer(5)]]) {
    float3 p = position[vid] + hull[vid] * (draw.misc.x * ink[vid]);
    MouthOut out;
    out.position = draw.viewProj * (draw.model * float4(p, 1));
    out.normal = (draw.model * float4(normal[vid], 0)).xyz;
    out.uv = uv[vid];
    return out;
}

// 0 below the edge, 1 above it, blended across about one pixel.
static float over(float value, float edge, float width) {
    return clamp((value - edge) / max(width, 1e-5) + 0.5, 0.0, 1.0);
}

fragment float4 mouth_fragment(MouthOut in [[stage_in]], bool front [[front_facing]],
                               constant MouthMaterial &m [[buffer(0)]],
                               constant MouthDraw &draw [[buffer(1)]]) {
    int kind = int(m.params.x);
    if (kind == 2) return float4(0);
    if (kind == 0) return float4(m.color.rgb, 1);

    float3 n = normalize(in.normal);
    if (!front) n = -n;
    float v = draw.misc.y * max(0.0, dot(n, draw.light.xyz)) + draw.misc.z;
    float dv = fwidth(v);
    float3 c = m.bandColor[0].rgb;
    int bands = int(m.params.y);
    for (int i = 1; i < bands; i++) c = mix(c, m.bandColor[i].rgb, over(v, m.bandAt[i], dv));

    float2 st = in.uv;
    if (m.params.w > 0) {
        float inner = 1 - over(st.y, m.params.w, fwidth(st.y));
        c = mix(c, c * m.bandTint.rgb, inner);
    }
    int strokes = int(m.params.z);
    float hit = 0;
    for (int i = 0; i < strokes; i++) {
        float4 s = m.strokes[i];
        float mid = st.y - (s.y + s.z) * 0.5;
        float du = abs(st.x - s.x - mid * mid * s.w);
        float along = 1 - abs(mid) / ((s.z - s.y) * 0.5);
        float w = pow(max(along, 0.0), 0.35) * m.bandTint.w;
        float px = fwidth(du);
        hit = max(hit, (1 - over(du, w, px)) * clamp(w / max(px, 1e-5), 0.0, 1.0));
    }
    c = mix(c, m.strokeColor.rgb, hit);
    return float4(c, 1);
}
"""#
}
