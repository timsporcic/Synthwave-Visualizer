/// Metal shader source, compiled at runtime with `makeLibrary(source:)` because this machine has
/// no offline Metal Toolchain. SceneRendererTests compiles it, so a shader error fails the tests.
/// Coordinates: `uv` is 0...1 with y down from the top; `p` is uv in height units centered on
/// the screen's vertical midline, so p.x spans ±aspect/2.
nonisolated enum ShaderSource {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct SceneUniforms {
    float width, height, time, horizon, sunRadius, cutShift, gridOffset, mids, bass, aberrationPixels, bloomStrength;
};

constant float3 kBackground = float3(0x0d, 0x02, 0x21) / 255.0;
constant float3 kPurple     = float3(0x8c, 0x1e, 0xff) / 255.0;
constant float3 kMagenta    = float3(0xff, 0x29, 0x75) / 255.0;
constant float3 kOrange     = float3(0xff, 0x90, 0x1f) / 255.0;
constant float3 kCyan       = float3(0x2d, 0xe2, 0xe6) / 255.0;
constant float3 kSun        = float3(0xff, 0xd3, 0x19) / 255.0;

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

struct FullscreenOut { float4 position [[position]]; float2 uv; };

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    // One oversized triangle covering the screen.
    float2 corner = float2((vid << 1) & 2, vid & 2);
    FullscreenOut out;
    out.position = float4(corner * 2.0 - 1.0, 0, 1);
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

static float3 skyColor(float y, float horizon) {
    if (y < 0.30) return mix(kBackground, kPurple, smoothstep(0.0, 0.30, y));
    if (y < 0.55) return mix(kPurple, kMagenta, (y - 0.30) / 0.25);
    return mix(kMagenta, kOrange, saturate((y - 0.55) / (horizon - 0.55)));
}

/// Anti-aliased distance (in pixels) to the nearest integer of `v`.
static float lineDistance(float v) {
    float d = abs(fract(v - 0.5) - 0.5);
    return d / max(fwidth(v), 1e-5);
}

fragment float4 sceneFragment(FullscreenOut in [[stage_in]], constant SceneUniforms &u [[buffer(0)]]) {
    float aspect = u.width / u.height;
    float2 p = float2((in.uv.x - 0.5) * aspect, in.uv.y);
    float3 color;

    if (p.y < u.horizon) {
        // Sky and sun
        color = skyColor(p.y, u.horizon);
        float2 fromSun = p - float2(0.0, u.horizon);
        float d = length(fromSun) / u.sunRadius;
        float height = (u.horizon - p.y) / u.sunRadius;  // 0 at horizon, 1 at the sun's top
        if (d < 1.0) {
            float3 sun = mix(kSun, kOrange, smoothstep(0.0, 0.55, d));
            sun = mix(sun, kMagenta, smoothstep(0.45, 1.0, d)) * 1.3;
            // Cut lines in the lower half: thin near the middle, widening toward the bottom.
            float period = 0.1;
            float v = height + u.cutShift;
            float gap = mix(0.55, 0.08, saturate(height / 0.5)) * period;
            bool cut = height < 0.5 && fract(v / period) * period < gap;
            float edge = smoothstep(1.0, 1.0 - 2.0 / (u.sunRadius * u.height), d);
            color = cut ? color : mix(color, sun, edge);
        } else {
            color += kMagenta * 0.35 * exp(-(d - 1.0) * 6.0);  // glow
        }
        // Haze along the horizon
        color += kMagenta * 0.25 * exp(-(u.horizon - p.y) * 60.0);
    } else {
        // Perspective grid: camera at height 1, focal length 1, so depth z = 1 / dy.
        float dy = p.y - u.horizon;
        float z = 1.0 / max(dy, 1e-4);
        float x = p.x * z;
        float xLine = lineDistance(x * 2.0);                 // lines every 0.5 world units
        float zLine = lineDistance(z + u.gridOffset);         // scrolls toward the camera
        // Fade each family where its lines are closer together than a few pixels; otherwise
        // they pile up into a solid band below the horizon.
        float xFade = 1.0 - smoothstep(0.12, 0.35, fwidth(x * 2.0));
        float zFade = 1.0 - smoothstep(0.12, 0.35, fwidth(z));
        float line = max((1.0 - smoothstep(0.0, 1.5, xLine)) * xFade, (1.0 - smoothstep(0.0, 1.5, zLine)) * zFade);
        float halo = max(exp(-xLine * 0.35) * xFade, exp(-zLine * 0.35) * zFade);
        float fade = smoothstep(0.0, 0.06, dy);
        float brightness = 0.9 + 1.4 * u.mids;
        color = kBackground * 0.7;
        color += kCyan * 0.12 * (1.0 - zFade) * fade;         // the faded lines' average glow
        color += kMagenta * 0.45 * halo * fade;
        color = mix(color, kCyan * brightness, line * fade);
        color += kMagenta * 0.35 * exp(-dy * 40.0);           // horizon glow on the ground
    }
    return float4(color, 1);
}

// Bars: 32 bars (16 bands mirrored around the sun) and 32 peak caps, standing on the grid plane.
struct BarOut {
    float4 position [[position]];
    float2 local;      // 0...1 across, 0...1 up
    float2 sizePixels;
    float cap;
};

vertex BarOut barVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                        constant SceneUniforms &u [[buffer(0)]], constant float *levels [[buffer(1)]]) {
    bool isCap = iid >= 32;
    uint bar = iid % 32;
    uint band = bar % 16;                       // lowest band nearest the sun
    float side = bar < 16 ? -1.0 : 1.0;
    float t = float(band) / 15.0;
    float aspect = u.width / u.height;
    float fit = min(1.0, aspect / (16.0 / 9.0));
    // World placement: a shallow arc, outer bars closer to the camera.
    float z = 5.5 - 1.2 * t * t;
    float worldX = side * (1.35 + float(band) * 0.14) * fit;
    float halfWidth = 0.05 * fit;
    float baseY = u.horizon + 1.0 / z;
    float centerX = worldX / z;
    float halfScreenWidth = halfWidth / z;
    float level = levels[band];
    float peak = levels[16 + band];
    float maxHeight = 1.25 / z;
    float bottom, top;
    if (isCap) {
        float capY = baseY - peak * maxHeight;
        bottom = capY;
        top = capY - 3.0 / u.height;
    } else {
        bottom = baseY;
        top = baseY - level * maxHeight;
    }
    float2 corner = float2(vid & 1, vid >> 1);  // triangle strip: (0,0) (1,0) (0,1) (1,1)
    float2 p = float2(centerX + (corner.x * 2.0 - 1.0) * halfScreenWidth, mix(bottom, top, corner.y));
    BarOut out;
    out.position = float4(p.x / aspect * 2.0, 1.0 - p.y * 2.0, 0, 1);
    out.local = corner;
    out.sizePixels = float2(2.0 * halfScreenWidth * u.height, max(bottom - top, 1e-5) * u.height);
    out.cap = isCap ? 1.0 : 0.0;
    return out;
}

fragment float4 barFragment(BarOut in [[stage_in]]) {
    if (in.cap > 0.5) return float4(kCyan * 1.8, 1);
    float3 fill = mix(kCyan, kMagenta, in.local.y);
    float2 edge = min(in.local, 1.0 - in.local) * in.sizePixels;
    bool outline = min(edge.x, edge.y) < 2.0;
    return float4(outline ? fill * 1.8 : fill * 0.95, 0.92);
}

// Post: bright pass, separable blur, composite.
fragment float4 brightPass(FullscreenOut in [[stage_in]], texture2d<float> scene [[texture(0)]]) {
    float3 c = scene.sample(linearClamp, in.uv).rgb;
    float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
    return float4(c * (max(lum - 0.8, 0.0) / max(lum, 1e-4)), 1);
}

fragment float4 blur(FullscreenOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                     constant float2 &direction [[buffer(0)]]) {
    const float weights[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
    float2 texel = direction / float2(source.get_width(), source.get_height());
    float3 sum = source.sample(linearClamp, in.uv).rgb * weights[0];
    for (int i = 1; i < 5; i++) {
        sum += source.sample(linearClamp, in.uv + texel * float(i) * 1.5).rgb * weights[i];
        sum += source.sample(linearClamp, in.uv - texel * float(i) * 1.5).rgb * weights[i];
    }
    return float4(sum, 1);
}

/// Integer hash of a lattice point to 0...1. The sin-based hash shows visible structure.
static float hash(float2 p) {
    uint2 q = uint2(int2(p)) * uint2(1597334673u, 3812015801u);
    uint n = (q.x ^ q.y) * 1597334673u;
    return float(n) * (1.0 / 4294967295.0);
}

static float valueNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 s = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), s.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), s.x), s.y);
}

fragment float4 composite(FullscreenOut in [[stage_in]], texture2d<float> scene [[texture(0)]],
                          texture2d<float> bloom [[texture(1)]], constant SceneUniforms &u [[buffer(0)]]) {
    float shift = u.aberrationPixels / u.width;
    float3 c = float3(scene.sample(linearClamp, in.uv + float2(shift, 0)).r,
                      scene.sample(linearClamp, in.uv).g,
                      scene.sample(linearClamp, in.uv - float2(shift, 0)).b);
    c += bloom.sample(linearClamp, in.uv).rgb * u.bloomStrength;
    if (uint(in.position.y) % 2 == 1) c *= 0.88;                    // CRT scanlines
    float2 fromCenter = (in.uv - 0.5) * float2(u.width / u.height, 1.0);
    c *= mix(1.0, 0.55, smoothstep(0.45, 1.1, length(fromCenter)));  // vignette
    float n = valueNoise(in.position.xy / 3.0 + float2(u.time * 7.0, u.time * 3.0));
    c = mix(c, float3(n), 0.03);                                     // drifting noise
    return float4(saturate(c), 1);
}
"""#
}
