// Shared hash / noise helpers for the comfy_cocoa shaders.
// Sin-free hashes (Dave Hoskins, "Hash without Sine") so large coordinates and
// long-running _Time stay stable on every GPU.
#ifndef COCOA_NOISE_INCLUDED
#define COCOA_NOISE_INCLUDED

float hash11(float p)
{
    p = frac(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return frac(p);
}

float hash12(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float hash13(float3 p3)
{
    p3 = frac(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return frac((p3.x + p3.y) * p3.z);
}

float2 hash22(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.xx + p3.yz) * p3.zy);
}

float3 hash33(float3 p3)
{
    p3 = frac(p3 * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return frac((p3.xxy + p3.yxx) * p3.zyx);
}

float vnoise2(float2 p)
{
    float2 i = floor(p);
    float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + float2(1, 0));
    float c = hash12(i + float2(0, 1));
    float d = hash12(i + float2(1, 1));
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}

float vnoise3(float3 p)
{
    float3 i = floor(p);
    float3 f = frac(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float n000 = hash13(i);
    float n100 = hash13(i + float3(1, 0, 0));
    float n010 = hash13(i + float3(0, 1, 0));
    float n110 = hash13(i + float3(1, 1, 0));
    float n001 = hash13(i + float3(0, 0, 1));
    float n101 = hash13(i + float3(1, 0, 1));
    float n011 = hash13(i + float3(0, 1, 1));
    float n111 = hash13(i + float3(1, 1, 1));
    return lerp(lerp(lerp(n000, n100, u.x), lerp(n010, n110, u.x), u.y),
                lerp(lerp(n001, n101, u.x), lerp(n011, n111, u.x), u.y), u.z);
}

// fbm with a fixed octave count (unrolled by the compiler)
float fbm2(float2 p)
{
    float s = 0.0, a = 0.5;
    [unroll] for (int i = 0; i < 5; i++)
    {
        s += a * vnoise2(p);
        p = mul(float2x2(1.6, 1.2, -1.2, 1.6), p) + 17.0;
        a *= 0.5;
    }
    return s;
}

float fbm2_3(float2 p)
{
    float s = 0.0, a = 0.5;
    [unroll] for (int i = 0; i < 3; i++)
    {
        s += a * vnoise2(p);
        p = mul(float2x2(1.6, 1.2, -1.2, 1.6), p) + 17.0;
        a *= 0.5;
    }
    return s / 0.875;
}

float fbm3(float3 p)
{
    float s = 0.0, a = 0.5;
    [unroll] for (int i = 0; i < 4; i++)
    {
        s += a * vnoise3(p);
        p = p * 2.03 + 11.7;
        a *= 0.5;
    }
    return s / 0.9375;
}

// Box-filtered periodic pulse: average over [x - w/2, x + w/2] of a pulse that is 1
// on [a, b] inside every unit period. Kills moire on far-away window grids.
float pulseIntegral(float x, float a, float b)
{
    return floor(x) * (b - a) + clamp(frac(x) - a, 0.0, b - a);
}

float filteredPulse(float x, float a, float b, float w)
{
    w = max(w, 1e-4);
    return (pulseIntegral(x + 0.5 * w, a, b) - pulseIntegral(x - 0.5 * w, a, b)) / w;
}

float sdBox2(float2 p, float2 halfSize)
{
    float2 d = abs(p) - halfSize;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

#endif
