// =====================================================================================
//  CityShading.cginc - what a building surface looks like.
//
//  Facade families (picked per lot, sometimes changed per stage):
//    0 RIBBON   continuous horizontal window bands between deep concrete spandrels
//    1 GRID     punched windows in a deep grid (the institute / ministry look)
//    2 FINS     vertical concrete fins, tall narrow windows
//    3 MONOLITH nearly blank walls, a few vertical slots and band windows: imposing
//    4 LOGGIA   deep recessed loggias behind solid balcony parapets
//  Below street level (y < 0) every wall becomes UNDERCITY: rough board-marked
//  concrete pierced by deep lit galleries/tunnels (the side-rooms going down forever).
//
//  Windows are drawn with fake depth: a reveal (sill with snow, jambs, head) and an
//  interior-mapped room lit by an incandescent lamp. Which windows are lit follows a
//  3D value-noise field (whole neighbourhoods of floors on/off) times _WindowLit.
//  Far away everything fades to an analytic average, so nothing sparkles in VR.
// =====================================================================================
#ifndef CITY_SHADING_INCLUDED
#define CITY_SHADING_INCLUDED

// ---------------------------------------------------------------- textures
float3 concreteSample(int tex, float2 uvm, float foot, out float3 nTS)
{
    float sz = FACADE_TEX_SIZE[tex];
    float2 uv = uvm / sz;
    float lod = log2(max(foot / sz * 1024.0, 1.0));
    float3 a = UNITY_SAMPLE_TEX2DARRAY_LOD(_FacadeAlbedo, float3(uv, tex), lod).rgb;
    nTS = UNITY_SAMPLE_TEX2DARRAY_LOD(_FacadeNormal, float3(uv, tex), lod).xyz * 2.0 - 1.0;
    nTS.xy *= saturate(1.5 - lod * 0.25);     // flatten normals at distance
    return a;
}

// ---------------------------------------------------------------- lighting
float sunShadow(float3 P, float3 n)
{
    if (_ShadowSteps <= 0 || _SunDir.w <= 0.0 || dot(n, _SunDir.xyz) <= 0.0) return 1.0;
    Hit s = traceCity(P + n * 0.3, _SunDir.xyz, _ShadowSteps, 3000.0, true);
    return s.face >= 0 ? 0.0 : 1.0;
}

float3 lightSurface(float3 P, float3 n, float3 alb, float shadow, float occl)
{
    float ndl = saturate(dot(n, _SunDir.xyz)) * _SunDir.w;
    float skyVis = lerp(0.4, 1.0, smoothstep(-300.0, 900.0, P.y)) * occl;
    float3 amb = _AmbientSky.rgb * (0.55 + 0.45 * n.y) * skyVis;
    float3 gnd = _AmbientGround.rgb * (0.65 - 0.35 * n.y) * (0.5 + 1.5 * smoothstep(500.0, -700.0, P.y));
    return alb * (_SunColor.rgb * ndl * shadow + amb + gnd);
}

// ---------------------------------------------------------------- lit windows
float windowLitProb(float3 P, uint ls)
{
    float3 o = float3(rndu(ls, 50u), rndu(ls, 52u), rndu(ls, 53u)) * 200.0;
    float n = vnoise3(P * float3(1.0 / 70.0, 1.0 / 26.0, 1.0 / 70.0) + o) * 0.7
            + vnoise3(P * (1.0 / 15.0) + o.zxy) * 0.3;
    float occupancy = lerp(0.15, 1.6, rndu(ls, 51u));
    return saturate(_WindowLit * occupancy * (0.2 + 1.6 * smoothstep(0.25, 0.75, n)));
}

float3 lampColor(uint rs)
{
    float r = rndu(rs, 60u);
    float3 c = r < 0.07 ? blackbody(4300.0) * float3(0.85, 1.0, 0.88)      // a cold tube light
                        : blackbody(lerp(2000.0, 3500.0, rndu(rs, 61u)));   // incandescent
    return c * lerp(0.55, 1.4, rndu(rs, 62u)) * _WindowIntensity;
}
static const float3 AVG_LAMP = float3(1.0, 0.6, 0.3);

// interior-mapped room behind a window. g: point on the glass (cell metres),
// rl: ray in wall space (x along wall, y up, z into the building)
float3 roomInterior(float2 g, float3 rl, float W, float FH, float depth, uint rs, float3 lamp)
{
    float tx = rl.x > 1e-5 ? (W - g.x) / rl.x : (rl.x < -1e-5 ? -g.x / rl.x : 1e9);
    float ty = rl.y > 1e-5 ? (FH - g.y) / rl.y : (rl.y < -1e-5 ? -g.y / rl.y : 1e9);
    float tz = depth / max(rl.z, 1e-4);
    float t = min(tx, min(ty, tz));
    float3 q = float3(g, 0.0) + rl * t;

    float3 wallp = lerp(float3(0.55, 0.45, 0.32), float3(0.35, 0.45, 0.38), rndu(rs, 70u));
    float3 alb;
    if (t == tz)      alb = wallp * (0.8 + 0.2 * step(0.5, frac(q.x * 2.0)));    // back wall, stripy paper
    else if (t == tx) alb = wallp * 0.85;
    else if (rl.y > 0) alb = float3(0.75, 0.72, 0.66);                           // ceiling
    else              alb = float3(0.22, 0.12, 0.07);                            // floor
    // a wardrobe / cabinet silhouette against the back
    if (t == tz && q.y < 2.0 && abs(q.x - W * rndu(rs, 71u)) < 0.6) alb *= 0.35;

    float3 Lp = float3(W * 0.5, FH - 0.35, depth * 0.45) - q;
    float3 irr = lamp * (2.2 / (1.0 + dot(Lp, Lp) * 0.45));
    float3 c = alb * irr;
    if (t == ty && rl.y > 0) c += lamp * 1.5 * exp(-dot(Lp.xz, Lp.xz) * 3.0);    // the bulb itself
    return c;
}

// window rectangle (cell metres: x0,x1,y0,y1) + reveal depth for each facade family
struct Facade { int style; int tex; float3 tint; float W; float4 win; float reveal; int tech; int pier; };

Facade facadeFor(Hit h, float len)
{
    uint fs = hashU(h.lotSeed, 7u);
    Facade F;
    F.style = int(rndu(fs, 0u) * 5.0);
    if (rndu(h.seed, 9u) < 0.3) F.style = int(rndu(h.seed, 10u) * 5.0);
    F.tex = int(rndu(fs, 1u) * 4.0);
    float g = lerp(0.9, 1.35, rndu(fs, 2u));
    F.tint = g * lerp(float3(1.0, 0.97, 0.92), float3(0.92, 0.96, 1.02), rndu(fs, 3u));
    float w0 = 3.5;
    float FH = CITY_FLOOR_H;
    F.tech = 9 + int(rndu(fs, 4u) * 14.0);           // technical floor every N floors
    F.pier = rndu(fs, 6u) < 0.55 ? 3 + int(rndu(fs, 7u) * 6.0) : 0;   // solid service-shaft piers every N bays
    if (F.style == 0)      { w0 = lerp(3.0, 6.0, rndu(fs, 5u)); }
    else if (F.style == 1) { w0 = lerp(3.6, 5.2, rndu(fs, 5u)); }
    else if (F.style == 2) { w0 = lerp(2.6, 3.8, rndu(fs, 5u)); }
    else if (F.style == 3) { w0 = lerp(2.5, 4.0, rndu(fs, 5u)); }
    else                   { w0 = lerp(3.6, 6.5, rndu(fs, 5u)); }
    F.W = len / max(1.0, round(len / w0));
    if (F.style == 0)      { F.win = float4(0.18, F.W - 0.18, 1.2, 2.35); F.reveal = 0.45; }
    else if (F.style == 1) { F.win = float4(F.W * 0.31, F.W * 0.69, 1.0, 2.4); F.reveal = 0.65; }
    else if (F.style == 2) { F.win = float4(0.6, F.W - 0.6, 0.55, FH - 0.5); F.reveal = 0.35; }
    else if (F.style == 3) { F.win = float4(F.W * 0.38, F.W * 0.62, 0.0, FH); F.reveal = 0.9; }
    else                   { F.win = float4(0.4, F.W - 0.4, 1.15, FH - 0.3); F.reveal = 1.6; }
    return F;
}

float3 snowAlbedo(float2 p)
{
    return float3(0.82, 0.86, 0.92) * (0.9 + 0.1 * vnoise2(p * 3.0));
}

// ---------------------------------------------------------------- far windows as points
// Far away, a block of S x S windows (S = 1, 2, 4, ... chosen from the pixel footprint)
// collapses into ONE glowing dot carrying the light of all its lit windows, so distant
// facades read as constellations of lit rooms instead of a smeared average. Level 0 uses
// the same hash as the close-up shading, so lit windows hand over seamlessly.
float3 windowDotsLevel(float u, float y, Facade F, Hit h, float litP, float foot, float effArea, float L)
{
    float FH = CITY_FLOOR_H;
    float S = exp2(L);
    float cw = F.W * S, ch = FH * S;
    float2 gp = float2(u / cw, y / ch);
    int2 base = int2(floor(gp - 0.5));
    float sg = max(foot * 0.55, 0.05);
    float3 acc = 0;
    int salt = int(h.lotSeed & 0xFFFFu) + h.face * 7919;
    [unroll] for (int j = 0; j < 2; j++)
    [unroll] for (int i = 0; i < 2; i++)
    {
        int2 c = base + int2(i, j);
        float n; float2 pos; float3 lamp;
        if (L < 0.5)
        {
            uint rs = hash3i(int3(c.x, c.y, salt));          // == the close-up window hash
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
        float E = n * effArea * 0.3;                          // window area x lit-window radiance
        acc += lamp * E / (6.2832 * sg * sg) * exp(-dot(d, d) / (2.0 * sg * sg));
    }
    return acc;
}

float3 farWindowDots(float u, float y, Facade F, Hit h, float litP, float foot, float effArea)
{
    float lv = clamp(log2(max(foot / min(F.W, CITY_FLOOR_H), 1e-3)) + 0.7, 0.0, 7.0);
    float l0 = floor(lv), fl = lv - l0;
    float3 a = windowDotsLevel(u, y, F, h, litP, foot, effArea, l0);
    if (fl < 0.02) return a;
    float3 b = windowDotsLevel(u, y, F, h, litP, foot, effArea, l0 + 1.0);
    return lerp(a, b, fl);
}

// ---------------------------------------------------------------- walls
float3 shadeWall(Hit h, float3 rd, float3 P, float pa, float shadow)
{
    float2 A, B; quadEdge(h.f, h.face, A, B);
    float2 E = B - A; float len = length(E); float2 T2 = E / len;
    float3 T = float3(T2.x, 0.0, T2.y);
    float3 N = float3(T2.y, 0.0, -T2.x);
    float u = dot(P.xz - A, T2);
    float y = P.y;
    float cosi = max(abs(dot(rd, N)), 0.2);
    float foot = h.t * pa / cosi;
    float3 rl = float3(dot(rd, T), rd.y, max(dot(rd, -N), 1e-3));
    float FH = CITY_FLOOR_H;

    Facade F = facadeFor(h, len);
    bool under = y < 0.0;

    float3 nTS;
    int tex = under ? 1 : F.tex;
    float3 alb = concreteSample(tex, float2(u, y), foot, nTS) * F.tint;
    // weathering: rain streaks under windows, big stains, grime deepening downwards
    float streak = vnoise2(float2(u * 0.9, y * 0.035 + rndu(h.lotSeed, 8u) * 50.0));
    float stain = fbm2(float2(u, y * 0.6) / 45.0 + rndu(h.lotSeed, 9u) * 30.0);
    alb *= lerp(1.0, 0.72, smoothstep(0.55, 0.9, streak) * (1.0 - saturate(foot * 0.2)));
    alb *= lerp(0.75, 1.1, stain);
    if (under) alb *= lerp(0.8, 0.45, saturate(-y / 1500.0));

    float3 nW = normalize(T * nTS.x + float3(0, 1, 0) * nTS.y + N * max(nTS.z, 0.3));
    float3 emis = 0;

    if (under)
    {
        // ---------------- UNDERCITY: galleries (side rooms) every G metres
        uint us = hashU(h.lotSeed, 0x51u + uint(h.face));
        float G = lerp(26.0, 58.0, rndu(us, 0u));
        float Hb = lerp(5.5, 10.0, rndu(us, 1u));
        float Wg = lerp(9.0, 16.0, rndu(us, 2u));
        Wg = len / max(1.0, round(len / Wg));
        float gy = y - floor(y / G) * G;
        float gx = u - floor(u / Wg) * Wg;
        int band = int(floor(y / G)), bay = int(floor(u / Wg));
        uint gs = hash3i(int3(band, bay, int(us & 0xFFFFu)));
        float4 r = float4(1.1, Wg - 1.1, 0.0, Hb);
        float k = saturate(foot / (0.3 * min(Wg, Hb)) - 1.0);
        bool lit = rndu(gs, 0u) < 0.6;
        float3 sod = lerp(float3(1.0, 0.45, 0.12), float3(1.0, 0.75, 0.45), rndu(gs, 1u)) * _UnderLit;
        float3 col = 0;
        if (k < 1.0)
        {
            float3 nearC;
            bool inO = gx > r.x && gx < r.y && gy > r.z && gy < r.w;
            if (inO)
            {
                // a long tunnel/room: box Wg x Hb x 40 m, ceiling light strips
                float2 g = float2(gx, gy);
                float tx = rl.x > 1e-5 ? (r.y - g.x) / rl.x : (rl.x < -1e-5 ? (r.x - g.x) / rl.x : 1e9);
                float ty = rl.y > 1e-5 ? (r.w - g.y) / rl.y : (rl.y < -1e-5 ? (r.z - g.y) / rl.y : 1e9);
                float tz = 40.0 / rl.z;
                float t = min(tx, min(ty, tz));
                float3 q = float3(g, 0) + rl * t;
                float fall = exp(-q.z * 0.05);
                float3 c = float3(0.05, 0.045, 0.04) * sod * fall;
                if (t == ty && rl.y > 0 && frac(q.z / 6.0) < 0.12 && abs(q.x - (r.x + r.y) * 0.5) < 0.5) c = sod * 3.0 * fall;
                else if (t == tz) c = sod * (lit ? 0.35 : 0.02) * step(abs(q.x - (r.x + r.y) * 0.5), 1.2) * step(q.y, 3.0) + c;
                else c += sod * 0.25 * fall * (t == ty && rl.y < 0 ? 1.0 : 0.4);
                nearC = lit ? c : c * 0.05;
            }
            else nearC = lightSurface(P, nW, alb, shadow, 0.8);
            col = nearC;
        }
        if (k > 0.0)
        {
            float frac0 = (r.y - r.x) * (r.w - r.z) / (Wg * G);
            float3 farC = lightSurface(P, N, alb, shadow, 0.8) * (1.0 - frac0)
                        + frac0 * sod * 0.35 * 0.6;
            col = k >= 1.0 ? farC : lerp(col, farC, k);
        }
        return col;
    }

    // ---------------- ABOVE STREET LEVEL
    int bay = int(floor(u / F.W));
    int flr = int(floor(y / FH));
    float cx = u - bay * F.W;
    float cy = y - flr * FH;
    bool cornice = (h.y1 - y) < 1.5 || (h.stage > 0 && (y - h.y0) < 0.6);
    bool tech = (uint(flr) % uint(F.tech)) == 0u;
    float4 r = F.win;
    if (F.style == 3)
    {
        // monolith: a vertical slot every 5th bay, a band window every 7th floor
        bool slot = (uint(bay) % 5u) == 2u;
        bool band = (uint(flr) % 7u) == 3u;
        if (band && !slot) r = float4(0.0, F.W, 1.3, 2.3);
        else if (!slot) r = float4(-1, -1, -1, -1);
    }
    bool pier = F.pier > 0 && F.style != 3 && (uint(bay) % uint(F.pier)) == 0u;
    if (cornice || tech || pier) r = float4(-1, -1, -1, -1);

    float minCell = min(F.W, FH);
    float k = saturate(foot / (0.3 * minCell) - 1.0);
    float litP = windowLitProb(P, h.lotSeed);
    float3 col = 0;

    if (k < 1.0)
    {
        bool inO = cx > r.x && cx < r.y && cy > r.z && cy < r.w;
        float3 nearC;
        if (inO)
        {
            float2 g = float2(cx, cy) + rl.xy / rl.z * F.reveal;
            bool glass = g.x > r.x && g.x < r.y && g.y > r.z && g.y < r.w;
            if (glass)
            {
                uint rs = hash3i(int3(bay, flr, int(h.lotSeed & 0xFFFFu) + h.face * 7919));
                bool lit = rndu(rs, 0u) < litP;
                float3 refl = skyColor(P, reflect(rd, N), false);
                float fres = 0.04 + 0.96 * pow(1.0 - saturate(rl.z), 5.0);
                if (lit)
                {
                    float3 lamp = lampColor(rs);
                    float3 room = roomInterior(float2(g.x, g.y), rl, F.W, FH, 5.0, rs, lamp);
                    // curtains / tulle on the glass
                    float cw = rndu(rs, 3u) * 0.45 * (r.y - r.x);
                    float wav = 0.06 * sin(g.y * 9.0 + g.x * 3.0);
                    bool curtain = (g.x - r.x) < cw + wav || (r.y - g.x) < cw * 0.7 + wav;
                    float3 ctint = lerp(float3(1.0, 0.55, 0.25), float3(0.9, 0.3, 0.2), rndu(rs, 4u));
                    if (rndu(rs, 5u) < 0.3) room = lerp(room, lamp * ctint * 0.35, 0.6);   // tulle
                    if (curtain) room = lamp * ctint * 0.3;
                    nearC = room * (1.0 - fres) + refl * fres * 0.5;
                }
                else
                {
                    float3 dark = lightSurface(P, N, float3(0.03, 0.03, 0.035), 0.0, 0.5);
                    nearC = dark + refl * (fres * 0.45 + 0.025);
                }
            }
            else
            {
                // reveal: sill (up, snowy), head (down), jambs
                float3 rn; float3 ra = alb * 0.85;
                if (g.y < r.z)      { rn = float3(0, 1, 0); ra = lerp(ra, snowAlbedo(float2(u, y)), _SnowCover * 0.9); }
                else if (g.y > r.w) { rn = float3(0, -1, 0); }
                else                { rn = g.x < r.x ? T : -T; }
                nearC = lightSurface(P, rn, ra, shadow * (rn.y > 0.5 ? 1.0 : 0.6), 0.6);
            }
        }
        else
        {
            float3 sa = alb;
            float3 sn = nW;
            // snow on the cornice lip and on the window heads below the sills
            if ((h.y1 - y) < 0.1) { sa = lerp(sa, snowAlbedo(float2(u, y)), _SnowCover); sn = float3(0, 1, 0); }
            // fins: protruding concrete at the bay edges, with a self-shadow on one side
            if (F.style == 2)
            {
                float fin = min(cx, F.W - cx);
                if (fin < 0.42) { sa *= 1.08; }
                float side = dot(T, _SunDir.xyz);
                float shade = side > 0 ? smoothstep(0.42, 0.42 + 0.8 * side, cx) : smoothstep(0.42, 0.42 - 0.8 * side, F.W - cx);
                shadow *= lerp(0.35, 1.0, shade);
            }
            if (tech) sa *= (frac(u * 2.0) < 0.5 ? 0.55 : 0.8);    // louvres on technical floors
            if (pier)
            {
                // the pier stands proud of the facade: lighter face, shadowed edge on the far side
                sa *= 1.12;
                float side = dot(T, _SunDir.xyz);
                float e = side > 0 ? cx : F.W - cx;
                shadow *= lerp(1.0, 0.55, smoothstep(0.35, 0.0, e) * abs(side) * 2.0);
            }
            nearC = lightSurface(P, sn, sa, shadow, 1.0);
            // window light spill on the spandrel just above lit windows (night glow)
        }
        col = nearC;
    }
    if (k > 0.0)
    {
        float ww = max(r.y - r.x, 0.0), wh = max(r.w - r.z, 0.0);
        float frac0 = saturate(ww * wh / (F.W * FH));
        if (F.style == 3) frac0 *= 0.32;
        if (F.pier > 0 && F.style != 3) frac0 *= 1.0 - 1.0 / F.pier;
        frac0 *= 1.0 - 1.0 / F.tech;
        float3 wallC = lightSurface(P, N, alb, shadow, 1.0);
        float3 glassC = lightSurface(P, N, float3(0.03, 0.03, 0.035), 0.0, 0.5)
                      + skyColor(P, reflect(rd, N), false) * 0.08;
        float3 farC = lerp(wallC, glassC, frac0)
                    + farWindowDots(u, y, F, h, litP, foot, frac0 * F.W * FH);
        col = k >= 1.0 ? farC : lerp(col, farC, k);
    }
    return col;
}

// ---------------------------------------------------------------- roofs and soffits
float3 shadeRoof(Hit h, float3 rd, float3 P, float pa, float shadow)
{
    float foot = h.t * pa / max(abs(rd.y), 0.2);
    // distance to the footprint edges
    float2 A[4] = { h.f.a, h.f.b, h.f.c, h.f.d };
    float2 B[4] = { h.f.b, h.f.c, h.f.d, h.f.a };
    float dmin = 1e9;
    [unroll] for (int e = 0; e < 4; e++)
        dmin = min(dmin, cross2(normalize(B[e] - A[e]), P.xz - A[e]));
    float3 nTS;
    Facade F = facadeFor(h, 10.0);
    float3 conc = concreteSample(F.tex, P.xz, foot, nTS) * F.tint * 0.8;
    float sn = _SnowCover * smoothstep(0.25, 0.6, fbm2(P.xz / 9.0)) ;
    sn = max(sn, _SnowCover * 0.85);
    float3 alb = lerp(conc, snowAlbedo(P.xz), sn);
    float3 n = float3(0, 1, 0);
    float3 emis = 0;

    // rooftop plant: vents / lift rooms as dark squares, some glowing
    float2 cell = floor(P.xz / 9.0);
    uint cs = hashU(hash2i(int2(cell)), h.seed);
    float2 fc = frac(P.xz / 9.0);
    if (dmin > 3.0 && rndu(cs, 0u) < 0.06 && all(abs(fc - 0.5) < 0.3)) { alb = lerp(conc, snowAlbedo(P.xz), 0.4); }
    // parapet
    if (dmin < 0.8) alb = lerp(conc * 1.1, snowAlbedo(P.xz), _SnowCover * 0.7);

    // aircraft warning lights on the corners of the tall ones
    if (h.y1 > 450.0)
    {
        float dc = min(min(length(P.xz - h.f.a), length(P.xz - h.f.b)), min(length(P.xz - h.f.c), length(P.xz - h.f.d)));
        float rad = max(1.2, foot * 1.5);
        float blink = step(0.5, frac(_Time.y * 0.5 + rndu(h.seed, 77u)));
        emis += float3(1.0, 0.05, 0.02) * 30.0 * blink * exp(-dc * dc / (rad * rad)) * (1.2 / rad);
    }
    return lightSurface(P, n, alb, shadow, 1.0) + emis;
}

float3 shadeSoffit(Hit h, float3 rd, float3 P, float pa)
{
    float3 nTS;
    float3 alb = concreteSample(1, P.xz, h.t * pa, nTS) * 0.5;
    float3 c = lightSurface(P, float3(0, -1, 0), alb, 0.0, 0.7);
    float2 g = frac(P.xz / 7.0);
    float strip = step(g.x, 0.06) * step(0.1, g.y) * step(g.y, 0.9);
    c += strip * float3(1.0, 0.6, 0.3) * _UnderLit * 1.5;
    return c;
}

float3 shadeHit(Hit h, float3 ro, float3 rd, float pa)
{
    float3 P = ro + rd * h.t;
    float3 N;
    if (h.face == 4) N = float3(0, 1, 0);
    else if (h.face == 5) N = float3(0, -1, 0);
    else { float2 A, B; quadEdge(h.f, h.face, A, B); float2 T2 = normalize(B - A); N = float3(T2.y, 0, -T2.x); }

    float shadow = (h.t < 4000.0) ? sunShadow(P, N) : 1.0;
    if (h.face == 4) return shadeRoof(h, rd, P, pa, shadow);
    if (h.face == 5) return shadeSoffit(h, rd, P, pa);
    return shadeWall(h, rd, P, pa, shadow);
}

#endif
