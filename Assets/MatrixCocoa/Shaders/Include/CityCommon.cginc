// =====================================================================================
//  CityCommon.cginc - uniforms, hashes and noise shared by every city shader.
//
//  The city's SHAPE is generated in C# (Editor/Gen/CityRules.cs) and baked into meshes.
//  The shaders only decide how surfaces LOOK. Per-time-of-day values are global shader
//  properties written by Editor/CityPresets.cs (so every city material shares them).
// =====================================================================================
#ifndef CITY_COMMON_INCLUDED
#define CITY_COMMON_INCLUDED

#define CITY_FLOOR_H 3.4         // must match CityRules.FloorH

// ---------------------------------------------------------------- globals (CityPresets.cs)
float4 _CityOffset;         // xyz: city position = world position + _CityOffset
float4 _SunDir;             // xyz: direction TO the sun, w: visibility (0 at night)
float4 _SunColor;
float4 _SkyZenith;
float4 _SkyHorizon;
float4 _CloudColor;
float  _CloudCover;
float4 _FogColor;
float  _FogDensity;         // extinction (1/m) at the viewer's altitude
float  _FogFalloff;         // height falloff scale (m)
float4 _AbyssColor;         // colour of the glowing depths
float4 _AmbientSky;
float4 _AmbientGround;
float  _WindowLit;
float  _WindowIntensity;
float  _UnderLit;
float  _CarIntensity;
float  _SnowCover;
float  _Exposure;
float  _AnchorAltitude;     // city altitude of world y = 0
float  _NeonIntensity;      // signs, car underglow

// the neon palette (signs, car underglow, some windows / galleries)
static const float3 NEON[8] =
{
    float3(1.0, 0.06, 0.42),   // hot pink
    float3(0.08, 0.78, 1.0),   // cyan
    float3(1.0, 0.1, 0.05),    // red
    float3(0.22, 1.0, 0.32),   // green
    float3(1.0, 0.5, 0.06),    // amber
    float3(0.5, 0.2, 1.0),     // violet
    float3(0.8, 0.88, 1.0),    // cold white
    float3(1.0, 0.82, 0.25),   // yellow
};

// height map of the roofs (for sun shadows / canyon occlusion)
sampler2D _CityHeight;
float4 _CityHeightRect;     // (minX, minZ, size, 1/size)

float3 worldToCity(float3 w) { return w + _CityOffset.xyz; }
float3 cityEye() { return worldToCity(_WorldSpaceCameraPos); }

// ---------------------------------------------------------------- hashing (integer PCG, = CityRules.cs)
uint pcg(uint v)
{
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}
uint hashU(uint a, uint b)      { return pcg(a ^ pcg(b + 0x9E3779B9u)); }
uint hash2i(int2 p)             { return pcg(uint(p.x) + pcg(uint(p.y) + 0x85EBCA6Bu)); }
uint hash3i(int3 p)             { return pcg(uint(p.x) + pcg(uint(p.y) + pcg(uint(p.z) + 0xC2B2AE35u))); }
float rndu(uint seed, uint k)   { return float(pcg(seed + k * 0x9E3779B9u) >> 8) * (1.0 / 16777216.0); }

// ---------------------------------------------------------------- value noise
float vnoise2(float2 p)
{
    int2 i = int2(floor(p)); float2 f = frac(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = rndu(hash2i(i), 0u),              b = rndu(hash2i(i + int2(1, 0)), 0u);
    float c = rndu(hash2i(i + int2(0, 1)), 0u), d = rndu(hash2i(i + int2(1, 1)), 0u);
    return lerp(lerp(a, b, u.x), lerp(c, d, u.x), u.y);
}
float vnoise3(float3 p)
{
    int3 i = int3(floor(p)); float3 f = frac(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float n000 = rndu(hash3i(i), 0u),                 n100 = rndu(hash3i(i + int3(1, 0, 0)), 0u);
    float n010 = rndu(hash3i(i + int3(0, 1, 0)), 0u), n110 = rndu(hash3i(i + int3(1, 1, 0)), 0u);
    float n001 = rndu(hash3i(i + int3(0, 0, 1)), 0u), n101 = rndu(hash3i(i + int3(1, 0, 1)), 0u);
    float n011 = rndu(hash3i(i + int3(0, 1, 1)), 0u), n111 = rndu(hash3i(i + int3(1, 1, 1)), 0u);
    return lerp(lerp(lerp(n000, n100, u.x), lerp(n010, n110, u.x), u.y),
                lerp(lerp(n001, n101, u.x), lerp(n011, n111, u.x), u.y), u.z);
}
float fbm2(float2 p)
{
    float s = 0, a = 0.5;
    [unroll] for (int i = 0; i < 4; i++) { s += a * vnoise2(p); p = p * 2.03 + 17.1; a *= 0.5; }
    return s / 0.9375;
}

float cross2(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }

float3 blackbody(float k)
{
    float t = max(k / 100.0, 20.0);
    float3 c;
    c.r = t <= 66.0 ? 1.0 : saturate(1.292936 * pow(t - 60.0, -0.1332047));
    c.g = t <= 66.0 ? saturate(0.3900816 * log(max(t, 1.0)) - 0.6318414) : saturate(1.129891 * pow(t - 60.0, -0.0755148));
    c.b = t >= 66.0 ? 1.0 : (t <= 19.0 ? 0.0 : saturate(0.5432068 * log(max(t - 10.0, 1.0)) - 1.1962541));
    return pow(c, 2.2);
}

// the shared tone curve: every city surface goes through this so they match
float3 cityTonemap(float3 x)
{
    x *= _Exposure;
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

#endif
