// =====================================================================================
//  CityCommon.cginc - constants, uniforms, hashes and noise shared by the city shader.
//
//  Two kinds of knobs live in this project:
//    * #defines below: structural layout constants (block size, floor height...).
//      Changing them reshapes the whole city.
//    * material properties (uniforms): per-preset look (sun, fog, lit windows...).
//      Written by Assets/MatrixCocoa/Editor/CityPresets.cs - edit the presets there.
// =====================================================================================
#ifndef CITY_COMMON_INCLUDED
#define CITY_COMMON_INCLUDED

// ---------------------------------------------------------------- layout constants
#define CITY_BLOCK        720.0     // spacing of the highway/boulevard lattice (m)
#define CITY_JITTER       0.17      // lattice vertex jitter, fraction of CITY_BLOCK (<0.25 keeps quads convex)
#define CITY_MAX_SPLIT    5         // divide-and-conquer depth inside each lattice block
#define CITY_MIN_SPLIT    170.0     // a region whose longest side is shorter than this is not split
#define CITY_FLOOR_H      3.4       // storey height (m); every stage is a whole number of floors
#define CITY_MAX_H        4200.0    // nothing is taller than this (ray early-out)
#define CITY_DEEP         -1.0e5    // "infinitely" deep: stage 0 foundations go down to here
#define VOID_LOT_PROB     0.045     // lots with no building: open shafts into the abyss
#define TITAN_PROB        0.022     // lots that grow a megatower (many stages)

#define LANE_DY           16.0      // vertical spacing of traffic strata (m)
#define LANE_W            4.5       // lateral lane spacing (m)
#define LANE_SLOT         34.0      // one car (or gap) per slot along a lane (m)
#define TRAFFIC_TOP       1400.0    // no lanes above this

#define ROW_SALT          0x2C1B3C6Du
#define COL_SALT          0x297A2D39u

// ---------------------------------------------------------------- uniforms (see CityPresets.cs)
float  _CitySeed;
float  _AnchorAltitude;     // city altitude (m) of world y = 0 (the glass room floor)
float4 _RoomMin;            // world-space AABB of the glass room (no snow inside)
float4 _RoomMax;

int    _MaxSteps;           // primary ray lot-steps
int    _ShadowSteps;        // sun shadow ray lot-steps (0 = no shadows)
int    _TrafficPlanes;      // traffic strata examined per pixel
int    _SnowSteps;          // falling-snow cells examined per pixel

float4 _SunDir;             // xyz: direction TO the sun, w: visibility (0 at night)
float4 _SunColor;           // rgb radiance of the sun
float4 _SkyZenith;
float4 _SkyHorizon;
float4 _CloudColor;
float  _CloudCover;
float4 _FogColor;
float  _FogDensity;         // extinction (1/m) at the viewer's altitude
float  _FogFalloff;         // height falloff scale (m)
float4 _AbyssColor;         // colour of the glowing depths (fog colour looking down)
float4 _AmbientSky;         // skylight on up-facing surfaces
float4 _AmbientGround;      // warm city/abyss glow lighting surfaces from below
float  _WindowLit;          // mean fraction of lit windows
float  _WindowIntensity;
float  _UnderLit;           // brightness of the undercity galleries
float  _CarIntensity;
float  _SnowAmount;         // falling-snow density 0..1
float  _SnowCover;          // snow on roofs/ledges 0..1
float  _Exposure;

UNITY_DECLARE_TEX2DARRAY(_FacadeAlbedo);   // slices: see Tools/fetch_polyhaven.py
UNITY_DECLARE_TEX2DARRAY(_FacadeNormal);
static const float FACADE_TEX_SIZE[4] = { 4.0, 2.0, 2.1, 2.09 };   // metres covered by one tile

// ---------------------------------------------------------------- hashing (integer, stable far from origin)
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
uint citySeed()                 { return uint(_CitySeed) * 0x01000193u + 0x811C9DC5u; }

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

// ---------------------------------------------------------------- misc
float cross2(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }
float2 perpL(float2 d)           { return float2(-d.y, d.x); }   // left normal (inward for CCW quads)

// approximate black-body colour (normalised, linear) for 1000..10000 K
float3 blackbody(float k)
{
    float t = max(k / 100.0, 20.0);
    float3 c;
    c.r = t <= 66.0 ? 1.0 : saturate(1.292936 * pow(t - 60.0, -0.1332047));
    c.g = t <= 66.0 ? saturate(0.3900816 * log(max(t, 1.0)) - 0.6318414) : saturate(1.129891 * pow(t - 60.0, -0.0755148));
    c.b = t >= 66.0 ? 1.0 : (t <= 19.0 ? 0.0 : saturate(0.5432068 * log(max(t - 10.0, 1.0)) - 1.1962541));
    return pow(c, 2.2);
}

#endif
