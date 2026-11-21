// =====================================================================================
//  CityShading.cginc - what a building surface looks like (used by CityFacade.shader).
//
//  Facade families (picked per lot, sometimes changed per stage):
//    0 RIBBON   continuous horizontal window bands between deep concrete spandrels
//    1 GRID     punched windows in a deep grid (the institute / ministry look)
//    2 FINS     vertical concrete fins, tall narrow windows
//    3 MONOLITH nearly blank walls, a few vertical slots and band windows
//    4 LOGGIA   deep recessed loggias behind solid balcony parapets
//  Below street level (y < 0) every wall becomes UNDERCITY: rough board-marked concrete
//  pierced by deep lit galleries - the side-rooms going down forever.
//
//  Windows: anti-aliased with screen derivatives, with fake depth (reveal + interior-mapped
//  rooms). Lit windows follow a 3D noise field times _WindowLit (incandescent black-body
//  lamps). Once a window is ~2 px, blocks of windows collapse into single bright dots that
//  carry their combined light (see farWindowDots) - constellations, not smears.
//  Sun shadows + canyon occlusion are traced through the roof height map.
// =====================================================================================
#ifndef CITY_SHADING_INCLUDED
#define CITY_SHADING_INCLUDED

UNITY_DECLARE_TEX2DARRAY(_FacadeAlbedo);   // slices: see Tools/fetch_polyhaven.py
UNITY_DECLARE_TEX2DARRAY(_FacadeNormal);
static const float FACADE_TEX_SIZE[4] = { 4.0, 2.0, 2.1, 2.09 };   // metres per tile
sampler2D _CityNoise;   // tiling noise (CityTextures.BuildNoise): R 8 cells, G fbm, B 16 cells, A 32 cells

// tiling noise lookup; `cells` = noise cells per tile of that channel, foot = pixel footprint in noise units
float4 noiseAt(float2 p, float cells, float foot)
{
    float lod = log2(max(foot / cells * 256.0, 1.0));
    return tex2Dlod(_CityNoise, float4(p / cells, 0, lod));
}

struct Surf
{
    float3 P;          // city position
    float3 N;          // outward normal
    float3 rd;         // eye -> surface (unit)
    float  dist;
    float  u, len;     // walls: along-wall coordinate and wall length
    float  edgeDist;   // roofs: distance to the footprint edge
    float  y0, y1;     // stage extent
    uint   lotSeed, seed;
    int    stage, face;
    float  foot;       // pixel footprint on the surface (m), the larger axis
    float2 foot2;      // walls: footprint along the wall (x) and up the wall (y)
};

// ---------------------------------------------------------------- textures
float3 concreteSample(int tex, float2 uvm, float foot, out float3 nTS)
{
    float sz = FACADE_TEX_SIZE[tex];
    float2 uv = uvm / sz;
    float lod = log2(max(foot / sz * 1024.0, 1.0));
    float3 a = UNITY_SAMPLE_TEX2DARRAY_LOD(_FacadeAlbedo, float3(uv, tex), lod).rgb;
    a = lerp(dot(a, float3(0.3, 0.59, 0.11)).xxx, a, 0.35);          // concrete is grey, not beige
    nTS = UNITY_SAMPLE_TEX2DARRAY_LOD(_FacadeNormal, float3(uv, tex), lod).xyz * 2.0 - 1.0;
    nTS.xy *= saturate(1.5 - lod * 0.25);
    return a;
}

// ---------------------------------------------------------------- height map: shadows & occlusion
float cityHeightAt(float2 xz)
{
    float2 uv = (xz - _CityHeightRect.xy) * _CityHeightRect.w;
    if (any(uv < 0.0) || any(uv > 1.0)) return -1e4;
    return tex2Dlod(_CityHeight, float4(uv, 0, 0)).r;
}

float sunShadow(float3 P, float3 N, bool roof)
{
    if (_SunDir.w <= 0.0 || dot(N, _SunDir.xyz) <= 0.0) return 1.0;
    float3 L = _SunDir.xyz;
    float3 o = P + (roof ? float3(0, 0.5, 0) : N * 6.0);
    float t = 2.0, sh = 1.0;
    [loop] for (int i = 0; i < 28; i++)
    {
        float3 q = o + L * t;
        float d = q.y - cityHeightAt(q.xz);
        sh = min(sh, saturate(d / (1.0 + t * 0.03)));      // soft penumbra
        if (sh <= 0.0 || q.y > 1800.0) break;
        t = t * 1.17 + 3.0;
        if (t > 3000.0) break;
    }
    return sh;
}

// how much sky a wall sees: the angle up to the opposite buildings
float canyonSky(float3 P, float3 N)
{
    float m = 0.0;
    [unroll] for (int i = 0; i < 3; i++)
    {
        float d = i == 0 ? 22.0 : (i == 1 ? 65.0 : 170.0);
        float h = cityHeightAt(P.xz + N.xz * d);
        m = max(m, atan2(h - P.y, d));
    }
    return lerp(1.0, 0.25, saturate(m / 1.5708));
}

float3 lightSurface(float3 P, float3 n, float3 alb, float shadow, float sky)
{
    float ndl = saturate(dot(n, _SunDir.xyz)) * _SunDir.w;
    float3 amb = _AmbientSky.rgb * (0.55 + 0.45 * n.y) * sky;
    float3 gnd = _AmbientGround.rgb * (0.65 - 0.35 * n.y) * (0.5 + 1.5 * smoothstep(500.0, -700.0, P.y));
    return alb * (_SunColor.rgb * ndl * shadow + amb + gnd);
}

// ---------------------------------------------------------------- lit windows
float windowLitProb(float u, float y, uint ls, int face)
{
    float2 o = float2(rndu(ls, 50u + uint(face)), rndu(ls, 52u)) * 64.0;
    float n = noiseAt(float2(u / 70.0, y / 26.0) + o, 16.0, 0.0).b * 0.7
            + noiseAt(float2(u, y) / 15.0 + o.yx, 32.0, 0.0).a * 0.3;
    float occupancy = lerp(0.15, 1.6, rndu(ls, 51u));
    return saturate(_WindowLit * occupancy * (0.2 + 1.6 * smoothstep(0.25, 0.75, n)));
}

float3 lampColor(uint rs)
{
    float r = rndu(rs, 60u);
    float3 c = blackbody(lerp(2000.0, 3500.0, rndu(rs, 61u)));               // incandescent
    if (r < 0.07)       c = blackbody(4300.0) * float3(0.8, 1.0, 0.82);          // a green-ish tube light
    else if (r < 0.11)  c = float3(0.45, 0.6, 1.0) * (0.55 + 0.45 * sin(_Time.y * (3.0 + 5.0 * rndu(rs, 63u)) + r * 90.0));  // TV glow
    else if (r < 0.135) c = NEON[pcg(rs) & 7u] * 0.8;                            // neon in the window
    return c * lerp(0.55, 1.4, rndu(rs, 62u)) * _WindowIntensity;
}

float3 roomInterior(float2 g, float3 rl, float W, float FH, float depth, uint rs, float3 lamp)
{
    float tx = rl.x > 1e-5 ? (W - g.x) / rl.x : (rl.x < -1e-5 ? -g.x / rl.x : 1e9);
    float ty = rl.y > 1e-5 ? (FH - g.y) / rl.y : (rl.y < -1e-5 ? -g.y / rl.y : 1e9);
    float tz = depth / max(rl.z, 1e-4);
    float t = min(tx, min(ty, tz));
    float3 q = float3(g, 0.0) + rl * t;
    float3 wallp = lerp(float3(0.55, 0.45, 0.32), float3(0.35, 0.45, 0.38), rndu(rs, 70u));
    float3 alb;
    if (t == tz)       alb = wallp * (0.8 + 0.2 * step(0.5, frac(q.x * 2.0)));
    else if (t == tx)  alb = wallp * 0.85;
    else if (rl.y > 0) alb = float3(0.75, 0.72, 0.66);
    else               alb = float3(0.22, 0.12, 0.07);
    if (t == tz && q.y < 2.0 && abs(q.x - W * rndu(rs, 71u)) < 0.6) alb *= 0.35;
    float3 Lp = float3(W * 0.5, FH - 0.35, depth * 0.45) - q;
    float3 c = alb * lamp * (2.2 / (1.0 + dot(Lp, Lp) * 0.45));
    if (t == ty && rl.y > 0) c += lamp * 1.5 * exp(-dot(Lp.xz, Lp.xz) * 3.0);
    return c;
}

struct Facade { int style; int tex; float3 tint; float W; float4 win; float reveal; int tech; int pier; };

Facade facadeFor(uint lotSeed, uint seed, float len)
{
    uint fs = hashU(lotSeed, 7u);
    Facade F;
    F.style = int(rndu(fs, 0u) * 5.0);
    if (rndu(seed, 9u) < 0.3) F.style = int(rndu(seed, 10u) * 5.0);
    F.tex = int(rndu(fs, 1u) * 4.0);
    float g = lerp(0.9, 1.35, rndu(fs, 2u));
    F.tint = g * lerp(float3(1.0, 0.97, 0.92), float3(0.92, 0.96, 1.02), rndu(fs, 3u));
    float FH = CITY_FLOOR_H;
    F.tech = 9 + int(rndu(fs, 4u) * 14.0);
    F.pier = rndu(fs, 6u) < 0.55 ? 3 + int(rndu(fs, 7u) * 6.0) : 0;
    float w0;
    if (F.style == 0)      w0 = lerp(3.0, 6.0, rndu(fs, 5u));
    else if (F.style == 1) w0 = lerp(3.6, 5.2, rndu(fs, 5u));
    else if (F.style == 2) w0 = lerp(2.6, 3.8, rndu(fs, 5u));
    else if (F.style == 3) w0 = lerp(2.5, 4.0, rndu(fs, 5u));
    else                   w0 = lerp(3.6, 6.5, rndu(fs, 5u));
    F.W = len / max(1.0, round(len / w0));
    if (F.style == 0)      { F.win = float4(0.18, F.W - 0.18, 1.2, 2.35); F.reveal = 0.45; }
    else if (F.style == 1) { F.win = float4(F.W * 0.31, F.W * 0.69, 1.0, 2.4); F.reveal = 0.65; }
    else if (F.style == 2) { F.win = float4(0.6, F.W - 0.6, 0.55, FH - 0.5); F.reveal = 0.35; }
    else if (F.style == 3) { F.win = float4(F.W * 0.38, F.W * 0.62, 0.0, FH); F.reveal = 0.9; }
    else                   { F.win = float4(0.4, F.W - 0.4, 1.15, FH - 0.3); F.reveal = 1.6; }
    return F;
}

float3 snowAlbedo(float2 p) { return float3(0.82, 0.86, 0.92) * (0.9 + 0.1 * noiseAt(p * 3.0, 16.0, 0.0).b); }

// 1D box-filtered coverage of [a, b] for a pixel of width w centred at x
float cover1(float x, float a, float b, float w)
{
    float h = 0.5 * w;
    return saturate((min(x + h, b) - max(x - h, a)) / max(w, 1e-4));
}

// ---------------------------------------------------------------- far windows as points
float3 windowDotsLevel(float u, float y, Facade F, uint lotSeed, int face, float litP, float2 foot, float effArea, float L)
{
    float FH = CITY_FLOOR_H;
    float S = exp2(L);
    float cw = F.W * S, ch = FH * S;
    int2 base = int2(floor(float2(u / cw, y / ch) - 0.5));
    float2 sg = max(foot * 0.42, 0.05);
    float3 acc = 0;
    int salt = int(lotSeed & 0xFFFFu) + face * 7919;
    [unroll] for (int j = 0; j < 2; j++)
    [unroll] for (int i = 0; i < 2; i++)
    {
        int2 c = base + int2(i, j);
        float n; float2 pos; float3 lamp;
        if (L < 0.5)
        {
            uint rs = hash3i(int3(c.x, c.y, salt));           // == the close-up window hash
            n = rndu(rs, 0u) < litP ? 1.0 : 0.0;
            pos = float2((c.x + 0.5) * F.W, c.y * FH + 0.5 * (F.win.z + F.win.w));
            lamp = lampColor(rs);
        }
        else
        {
            uint cs = hash3i(int3(c.x, c.y, salt + int(L) * 104729));
            float nl = S * S * litP * lerp(0.3, 1.7, rndu(cs, 1u));
            n = nl >= 1.0 ? floor(nl + rndu(cs, 2u)) : (rndu(cs, 2u) < nl ? 1.0 : 0.0);
            pos = (float2(c) + 0.15 + 0.7 * float2(rndu(cs, 3u), rndu(cs, 4u))) * float2(cw, ch);
            lamp = lampColor(cs);
        }
        if (n <= 0.0) continue;
        float2 d = float2(u, y) - pos;
        float E = n * effArea * 0.3;
        float2 z = d / sg;
        acc += lamp * E / (6.2832 * sg.x * sg.y) * exp(-0.5 * dot(z, z));
    }
    return acc;
}

float3 farWindowDots(float u, float y, Facade F, uint lotSeed, int face, float litP, float2 foot, float effArea)
{
    float lv = clamp(log2(max(max(foot.x / F.W, foot.y / CITY_FLOOR_H), 1e-3)) + 0.7, 0.0, 7.0);
    float l0 = floor(lv), fl = lv - l0;
    float3 a = windowDotsLevel(u, y, F, lotSeed, face, litP, foot, effArea, l0);
    if (fl < 0.02) return a;
    float3 b = windowDotsLevel(u, y, F, lotSeed, face, litP, foot, effArea, l0 + 1.0);
    return lerp(a, b, fl);
}

// ---------------------------------------------------------------- undercity walls
float3 shadeUnder(Surf s, float3 T, float3 rl, float3 alb, float3 nW)
{
    float u = s.u, y = s.P.y;
    uint us = hashU(s.lotSeed, 0x51u + uint(s.face));
    float G = lerp(26.0, 58.0, rndu(us, 0u));
    float Hb = lerp(5.5, 10.0, rndu(us, 1u));
    float Wg = lerp(9.0, 16.0, rndu(us, 2u));
    Wg = s.len / max(1.0, round(s.len / Wg));
    float gy = y - floor(y / G) * G;
    float gx = u - floor(u / Wg) * Wg;
    int band = int(floor(y / G)), bay = int(floor(u / Wg));
    uint gs = hash3i(int3(band, bay, int(us & 0xFFFFu)));
    float4 r = float4(1.1, Wg - 1.1, 0.0, Hb);
    bool lit = rndu(gs, 0u) < 0.6;
    float3 sod = lerp(float3(1.0, 0.45, 0.12), float3(1.0, 0.75, 0.45), rndu(gs, 1u)) * _UnderLit;
    if (rndu(gs, 2u) < 0.05) sod = NEON[pcg(gs) & 7u] * _UnderLit * 0.6;     // the odd neon-lit gallery

    float3 wallC = lightSurface(s.P, nW, alb, 0.0, 0.35);
    float cov = cover1(gx, r.x, r.y, s.foot2.x) * cover1(gy, r.z, r.w, s.foot2.y);
    float k = saturate(max(s.foot2.x / Wg, s.foot2.y / Hb) / 0.25 - 1.0);
    float3 col = wallC;
    if (cov > 0.0 && k < 1.0)
    {
        // a long tunnel / hall: Wg x Hb x 40 m, ceiling light strips
        float2 g = float2(clamp(gx, r.x, r.y), clamp(gy, r.z, r.w));
        float tx = rl.x > 1e-5 ? (r.y - g.x) / rl.x : (rl.x < -1e-5 ? (r.x - g.x) / rl.x : 1e9);
        float ty = rl.y > 1e-5 ? (r.w - g.y) / rl.y : (rl.y < -1e-5 ? (r.z - g.y) / rl.y : 1e9);
        float tz = 40.0 / rl.z;
        float t = min(tx, min(ty, tz));
        float3 q = float3(g, 0) + rl * t;
        float fall = exp(-q.z * 0.05);
        float3 c = float3(0.05, 0.045, 0.04) * sod * fall;
        if (t == ty && rl.y > 0 && frac(q.z / 6.0) < 0.12 && abs(q.x - (r.x + r.y) * 0.5) < 0.5) c = sod * 3.0 * fall;
        else if (t == tz) c += sod * (lit ? 0.35 : 0.02) * step(abs(q.x - (r.x + r.y) * 0.5), 1.2) * step(q.y, 3.0);
        else c += sod * 0.25 * fall * (t == ty && rl.y < 0 ? 1.0 : 0.4);
        col = lerp(wallC, lit ? c : c * 0.05, cov);
    }
    if (k > 0.0)
    {
        float frac0 = (r.y - r.x) * (r.w - r.z) / (Wg * G);
        float3 farC = wallC * (1.0 - frac0) + frac0 * sod * 0.35 * 0.6;
        col = lerp(col, farC, k);
    }
    return col;
}

// ---------------------------------------------------------------- walls
float3 shadeWall(Surf s)
{
    float3 N = s.N;
    float3 T = normalize(cross(N, float3(0, 1, 0)));
    float u = s.u, y = s.P.y;
    float3 rd = s.rd;
    float3 rl = float3(dot(rd, T), rd.y, max(dot(rd, -N), 1e-3));
    float FH = CITY_FLOOR_H;
    Facade F = facadeFor(s.lotSeed, s.seed, s.len);
    bool under = y < 0.0;

    float3 nTS;
    float3 alb = concreteSample(under ? 1 : F.tex, float2(u, y), s.foot, nTS) * F.tint;
    float streak = noiseAt(float2(u * 0.9, y * 0.035 + rndu(s.lotSeed, 8u) * 50.0), 8.0, s.foot * 0.9).r;
    float stain = noiseAt(float2(u, y * 0.6) / 45.0 + rndu(s.lotSeed, 9u) * 30.0, 8.0, s.foot / 45.0).g;
    alb *= lerp(1.0, 0.72, smoothstep(0.55, 0.9, streak) * (1.0 - saturate(s.foot * 0.2)));
    alb *= lerp(0.75, 1.1, stain);
    if (under) alb *= lerp(0.8, 0.45, saturate(-y / 1500.0));
    float3 nW = normalize(T * nTS.x + float3(0, 1, 0) * nTS.y + N * max(nTS.z, 0.3));

    if (under) return shadeUnder(s, T, rl, alb, nW);

    float sky = canyonSky(s.P, N);
    float shadow = sunShadow(s.P, N, false);

    int bay = int(floor(u / F.W));
    int flr = int(floor(y / FH));
    float cx = u - bay * F.W;
    float cy = y - flr * FH;
    bool cornice = (s.y1 - y) < 1.5 || (s.stage > 0 && (y - s.y0) < 0.6);
    bool tech = (uint(flr) % uint(F.tech)) == 0u;
    float4 r = F.win;
    if (F.style == 3)
    {
        bool slot = (uint(bay) % 5u) == 2u;
        bool band = (uint(flr) % 7u) == 3u;
        if (band && !slot) r = float4(0.0, F.W, 1.3, 2.3);
        else if (!slot) r = float4(-1, -1, -1, -1);
    }
    bool pier = F.pier > 0 && F.style != 3 && (uint(bay) % uint(F.pier)) == 0u;
    if (cornice || tech || pier) r = float4(-1, -1, -1, -1);

    float minCell = min(F.W, FH);
    float k = saturate(max(s.foot2.x / F.W, s.foot2.y / FH) / 0.45 - 1.0);   // windows below ~2 px -> dots
    float litP = windowLitProb(u, y, s.lotSeed, s.face);

    // ---- the wall itself
    float3 sa = alb, sn = nW;
    float wshadow = shadow;
    if ((s.y1 - y) < 0.1) { sa = lerp(sa, snowAlbedo(float2(u, y)), _SnowCover); sn = float3(0, 1, 0); }
    if (F.style == 2)
    {
        float side = dot(T, _SunDir.xyz);
        float shade = side > 0 ? smoothstep(0.42, 0.42 + 0.8 * side, cx) : smoothstep(0.42, 0.42 - 0.8 * side, F.W - cx);
        wshadow *= lerp(0.35, 1.0, shade);
    }
    if (tech) sa *= (frac(u * 2.0) < 0.5 ? 0.55 : 0.8);
    if (pier)
    {
        sa *= 1.12;
        float side = dot(T, _SunDir.xyz);
        float e = side > 0 ? cx : F.W - cx;
        wshadow *= lerp(1.0, 0.55, smoothstep(0.35, 0.0, e) * abs(side) * 2.0);
    }
    float3 wallC = lightSurface(s.P, sn, sa, wshadow, sky);
    float3 col = wallC;

    // ---- windows (near): anti-aliased opening with reveal + interior
    if (k < 1.0)
    {
        float cov = cover1(cx, r.x, r.y, s.foot2.x) * cover1(cy, r.z, r.w, s.foot2.y);
        if (cov > 0.0)
        {
            float2 c0 = float2(clamp(cx, r.x, r.y), clamp(cy, r.z, r.w));
            float2 g = c0 + rl.xy / rl.z * F.reveal;
            float3 openC;
            bool glass = g.x > r.x && g.x < r.y && g.y > r.z && g.y < r.w;
            if (glass)
            {
                uint rs = hash3i(int3(bay, flr, int(s.lotSeed & 0xFFFFu) + s.face * 7919));
                bool lit = rndu(rs, 0u) < litP;
                float3 refl = skyColor(s.P, reflect(rd, N), false);
                float fres = 0.04 + 0.96 * pow(1.0 - saturate(rl.z), 5.0);
                if (lit)
                {
                    float3 lamp = lampColor(rs);
                    float3 room = roomInterior(g, rl, F.W, FH, 5.0, rs, lamp);
                    float cw = rndu(rs, 3u) * 0.45 * (r.y - r.x);
                    float wav = 0.06 * sin(g.y * 9.0 + g.x * 3.0);
                    bool curtain = (g.x - r.x) < cw + wav || (r.y - g.x) < cw * 0.7 + wav;
                    float3 ctint = lerp(float3(1.0, 0.55, 0.25), float3(0.9, 0.3, 0.2), rndu(rs, 4u));
                    if (rndu(rs, 5u) < 0.3) room = lerp(room, lamp * ctint * 0.35, 0.6);
                    if (curtain) room = lamp * ctint * 0.3;
                    openC = room * (1.0 - fres) + refl * fres * 0.5;
                }
                else
                {
                    openC = lightSurface(s.P, N, float3(0.03, 0.03, 0.035), 0.0, 0.5) + refl * (fres * 0.45 + 0.025);
                }
            }
            else
            {
                float3 rn; float3 ra = alb * 0.85;
                if (g.y < r.z)      { rn = float3(0, 1, 0); ra = lerp(ra, snowAlbedo(float2(u, y)), _SnowCover * 0.9); }
                else if (g.y > r.w) { rn = float3(0, -1, 0); }
                else                { rn = g.x < r.x ? T : -T; }
                openC = lightSurface(s.P, rn, ra, shadow * (rn.y > 0.5 ? 1.0 : 0.6), sky * 0.6);
            }
            col = lerp(wallC, openC, cov);
        }
    }
    // ---- windows (far): wall/glass average + lit rooms as dots
    if (k > 0.0)
    {
        float frac0 = saturate((F.win.y - F.win.x) * (F.win.w - F.win.z) / (F.W * FH));
        if (F.style == 3) frac0 *= 0.32;
        if (F.pier > 0 && F.style != 3) frac0 *= 1.0 - 1.0 / F.pier;
        frac0 *= 1.0 - 1.0 / F.tech;
        float3 glassC = lightSurface(s.P, N, float3(0.03, 0.03, 0.035), 0.0, 0.5)
                      + skyColor(s.P, reflect(rd, N), false) * 0.06;
        float3 wallAvg = lightSurface(s.P, N, alb, shadow, sky);
        float3 farC = lerp(wallAvg, glassC, frac0)
                    + farWindowDots(u, y, F, s.lotSeed, s.face, litP, s.foot2, frac0 * F.W * FH);
        col = lerp(col, farC, k);
    }
    return col;
}

// ---------------------------------------------------------------- roofs and soffits
float3 shadeRoof(Surf s)
{
    float3 P = s.P;
    float3 nTS;
    Facade F = facadeFor(s.lotSeed, s.seed, 10.0);
    float3 conc = concreteSample(F.tex, P.xz, s.foot, nTS) * F.tint * 0.8;
    float sn = max(_SnowCover * smoothstep(0.25, 0.6, noiseAt(P.xz / 9.0, 8.0, s.foot / 9.0).g), _SnowCover * 0.85);
    float3 alb = lerp(conc, snowAlbedo(P.xz), sn);
    float3 emis = 0;

    float2 cell = floor(P.xz / 9.0);
    uint cs = hashU(hash2i(int2(cell)), s.seed);
    float2 fc = frac(P.xz / 9.0);
    if (s.edgeDist > 3.0 && rndu(cs, 0u) < 0.06 && all(abs(fc - 0.5) < 0.3)) alb = lerp(conc, snowAlbedo(P.xz), 0.4);
    float par = 1.0 - smoothstep(0.7, 0.7 + s.foot, s.edgeDist);
    alb = lerp(alb, lerp(conc * 1.1, snowAlbedo(P.xz), _SnowCover * 0.7), par);

    // aircraft warning lights along the edges of the tall ones
    if (s.y1 > 450.0)
    {
        float rad = max(1.2, s.foot * 1.5);
        float blink = step(0.5, frac(_Time.y * 0.5 + rndu(s.seed, 77u)));
        emis += float3(1.0, 0.05, 0.02) * 20.0 * blink * exp(-s.edgeDist * s.edgeDist / (rad * rad)) * (1.2 / rad)
              * step(0.85, noiseAt(P.xz * 0.15, 8.0, 0.0).r);
    }
    float shadow = sunShadow(P, float3(0, 1, 0), true);
    return lightSurface(P, float3(0, 1, 0), alb, shadow, 1.0) + emis;
}

float3 shadeSoffit(Surf s)
{
    float3 nTS;
    float3 alb = concreteSample(1, s.P.xz, s.foot, nTS) * 0.5;
    float3 c = lightSurface(s.P, float3(0, -1, 0), alb, 0.0, 0.7);
    float2 g = frac(s.P.xz / 7.0);
    float strip = step(g.x, 0.06) * step(0.1, g.y) * step(g.y, 0.9);
    c += strip * float3(1.0, 0.6, 0.3) * _UnderLit * 1.5;
    return c;
}

float3 shadeSurface(Surf s)
{
    if (s.face == 4) return shadeRoof(s);
    if (s.face == 5) return shadeSoffit(s);
    return shadeWall(s);
}

#endif
