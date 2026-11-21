// =====================================================================================
//  CityTraffic.cginc - floating cars.
//
//  Traffic flies in horizontal STRATA every LANE_DY metres. On each stratum, every
//  street has lanes every LANE_W metres either side of its centre line (right-hand
//  traffic), and sky-streets (the gaps that split stage-1 towers) get lanes too, above
//  the stage-0 roofs. Only some strata of a given street carry traffic, and density
//  falls off with altitude, so looking down you see layered rivers of white headlights
//  and red tail lights thickening into the depths.
//
//  Level of detail (a bubble around the viewer):
//    < CAR_BODY_NEAR  sleek ray-marched bodies (signed distance fields) + lights
//    .. CAR_BODY_FAR  bodies fade out
//    beyond           lights only (glare-widened splats) -> the rivers of light
//
//  Per pixel: for each stratum the ray crosses before hitting a building, find the lot
//  under the crossing point and the lane it is in, splat the lights of the nearest cars
//  (3 slots; 3 lanes when close) and remember the nearest car whose bounding box the ray
//  enters. Only that one car is ray-marched.
// =====================================================================================
#ifndef CITY_TRAFFIC_INCLUDED
#define CITY_TRAFFIC_INCLUDED

#define CAR_SALOON 0
#define CAR_VAN    1
#define CAR_BUS    2
#define CAR_HAULER 3

#define CAR_BODY_NEAR 170.0
#define CAR_BODY_FAR  300.0

struct Traffic
{
    float3 light;     // additive light (already fogged)
    float3 body;      // shaded body colour (not fogged yet)
    float  bodyT;     // ray distance to the body, 1e9 = none
    float  bodyA;     // body opacity (LOD fade)
    // candidate for ray-marching (nearest bounding box entered on this stratum)
    float  cT;
    float3 cC;
    float3 cF;        // forward (unit)
    int    cKind;
    uint   cSeed;
};

float laneDensity(float y)
{
    return y < 0.0 ? 0.85 : 0.85 * exp(-y / 300.0);
}

float3 splatLight(float3 Lp, float3 col, float r, float3 ro, float3 rd, float pa, float tLimit)
{
    float3 v = Lp - ro;
    float tt = dot(v, rd);
    if (tt <= 0.0 || tt > tLimit) return 0;
    float d2 = max(dot(v, v) - tt * tt, 0.0);
    float sg = max(r, tt * pa * 0.8);
    float e = (r * r) / (sg * sg);
    return col * pow(e, 0.8) * exp(-d2 / (sg * sg));
}

// bounding half-extents (x forward, y up, z side) per vehicle kind
float3 carBounds(int kind)
{
    if (kind == CAR_SALOON) return float3(2.45, 0.85, 0.95);
    if (kind == CAR_VAN)    return float3(2.65, 1.02, 1.04);
    if (kind == CAR_BUS)    return float3(5.7, 1.32, 1.26);
    return float3(6.3, 1.55, 1.32);
}

float boxEntry(float3 o, float3 d, float3 he)
{
    float3 inv = 1.0 / (abs(d) > 1e-6 ? d : 1e-6);
    float3 t0 = (-he - o) * inv, t1 = (he - o) * inv;
    float3 tmn = min(t0, t1), tmx = max(t0, t1);
    float tn = max(max(tmn.x, tmn.y), tmn.z);
    float tf = min(min(tmx.x, tmx.y), tmx.z);
    return (tn <= tf && tf > 0.0) ? max(tn, 0.0) : 1e9;
}

// ---------------------------------------------------------------- shapes (SDF, car frame)
float sdRoundBox(float3 p, float3 b, float r)
{
    float3 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}
float sdEllipsoid(float3 p, float3 r)
{
    float k0 = length(p / r), k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 1e-5);
}
float smin(float a, float b, float k)
{
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

// part: 0 paint, 1 glass, 2 dark trim
float carSDF(int kind, float3 q, out int part)
{
    part = 0;
    if (kind == CAR_SALOON)
    {
        // a long low hull, banana-curved so nose and tail dip, with a teardrop canopy
        float3 p = q; p.y += 0.035 * p.x * p.x - 0.05;
        p.z *= 1.0 + 0.06 * max(-p.x, 0.0);                    // tapers towards the tail
        float hull = sdRoundBox(p, float3(2.35, 0.27, 0.86), 0.26);
        float canopy = sdEllipsoid(q - float3(-0.45, 0.3, 0), float3(1.2, 0.34, 0.62));
        float d = smin(hull, canopy, 0.2);
        if (canopy < hull && q.y > 0.2 && q.y < 0.52) part = 1;   // side/front glass, painted roof
        if (abs(q.y + 0.02) < 0.035) part = 2;                 // chrome-ish belt line
        return d;
    }
    if (kind == CAR_VAN)
    {
        float d = sdRoundBox(q, float3(2.55, 0.94, 0.98), 0.42);
        d = max(d, dot(q - float3(2.15, 0.55, 0), float3(0.62, 0.78, 0)));   // raked nose
        if (q.x > 1.55 && q.y > 0.05) part = 1;
        if (abs(q.y + 0.35) < 0.05) part = 2;
        return d;
    }
    if (kind == CAR_BUS)
    {
        float d = sdRoundBox(q, float3(5.6, 1.22, 1.18), 0.45);
        if (q.y > 0.05 && q.y < 0.85 && frac(q.x / 1.6 + 0.5) > 0.08) part = 1;
        if (q.x > 4.9 && q.y > -0.2) part = 1;
        return d;
    }
    // freight hauler: rounded cab + slab container
    float cab = sdRoundBox(q - float3(5.1, 0.0, 0), float3(1.1, 1.3, 1.2), 0.55);
    float box = sdRoundBox(q - float3(-1.1, 0.1, 0), float3(5.1, 1.42, 1.28), 0.08);
    if (cab < box && q.x > 5.3 && q.y > 0.2) part = 1;
    if (box < cab && frac(q.x / 0.7) < 0.1) part = 2;           // container ribs
    return min(cab, box);
}

static const float3 CAR_PAINT[8] =
{
    float3(0.20, 0.03, 0.025), // oxblood
    float3(0.045, 0.05, 0.055),// graphite
    float3(0.03, 0.045, 0.09), // navy
    float3(0.5, 0.52, 0.54),   // silver
    float3(0.012, 0.012, 0.014), // black (the party official)
    float3(0.06, 0.1, 0.07),   // bottle green
    float3(0.42, 0.28, 0.05),  // ochre (taxi)
    float3(0.25, 0.26, 0.27),  // gunmetal
};

float3 shadeCar(int kind, uint cs, float3 q, int part, float3 nW, float3 rd)
{
    float3 paint = CAR_PAINT[pcg(cs) & 7u];
    if (kind == CAR_HAULER) paint = lerp(float3(0.16, 0.15, 0.13), paint, 0.3);
    if (kind == CAR_BUS)    paint = q.y > -0.15 ? float3(0.52, 0.47, 0.36) : float3(0.26, 0.035, 0.025);  // cream over red

    float up = nW.y * 0.5 + 0.5;
    float3 amb = _AmbientSky.rgb * up + _AmbientGround.rgb * 2.5 * (1.0 - up);
    float ndl = saturate(dot(nW, _SunDir.xyz)) * _SunDir.w;
    float3 refl = skyColor(float3(0, 0, 0), reflect(rd, nW), false);
    float fres = 0.04 + 0.96 * pow(1.0 - saturate(dot(-rd, nW)), 5.0);

    if (part == 1)
    {
        float3 c = refl * (fres * 0.85 + 0.05);
        if (kind == CAR_BUS && rndu(cs, 9u) < 0.85) c += float3(1.0, 0.62, 0.3) * 0.3 * _WindowIntensity * saturate(_WindowLit * 2.5);
        else c += float3(0.6, 0.8, 1.0) * 0.02 * _CarIntensity;            // dashboard glow
        return c;
    }
    float3 alb = part == 2 ? paint * 0.35 + 0.02 : paint;
    float3 c = alb * (amb + _SunColor.rgb * ndl) + refl * (fres * 0.6 + 0.03);   // glossy lacquer
    // warm lift pads glowing underneath
    if (nW.y < -0.4)
    {
        float3 he = carBounds(kind);
        float2 pp = float2(abs(q.x) - he.x * 0.55, abs(q.z) - he.z * 0.5);
        c += float3(1.0, 0.42, 0.12) * 4.0 * exp(-dot(pp, pp) * 8.0);
    }
    return c;
}

// ray-march the remembered candidate car; fills tr.body / bodyT / bodyA on a hit
void marchCar(float3 ro, float3 rd, inout Traffic tr)
{
    float3 F = tr.cF, U = float3(0, 1, 0), S = float3(-F.z, 0, F.x);
    float3 o = ro - tr.cC;
    float3 lo = float3(dot(o, F), o.y, dot(o, S));
    float3 ld = float3(dot(rd, F), rd.y, dot(rd, S));
    float t = max(tr.cT - 0.05, 0.0);
    float tEnd = tr.cT + 2.0 * length(carBounds(tr.cKind)) + 0.5;
    int part = 0;
    bool hit = false;
    [loop] for (int i = 0; i < 28; i++)
    {
        float d = carSDF(tr.cKind, lo + ld * t, part);
        if (d < 0.003 + t * 0.0004) { hit = true; break; }
        t += d;
        if (t > tEnd) break;
    }
    if (!hit) return;
    float3 q = lo + ld * t;
    const float2 k = float2(1, -1) * 0.01;
    int pp;
    float3 nl = normalize(k.xyy * carSDF(tr.cKind, q + k.xyy, pp) + k.yyx * carSDF(tr.cKind, q + k.yyx, pp)
                        + k.yxy * carSDF(tr.cKind, q + k.yxy, pp) + k.xxx * carSDF(tr.cKind, q + k.xxx, pp));
    float3 nW = nl.x * F + nl.y * U + nl.z * S;
    tr.bodyT = t;
    tr.body = shadeCar(tr.cKind, tr.cSeed, q, part, nW, rd);
    tr.bodyA = 1.0 - smoothstep(CAR_BODY_NEAR, CAR_BODY_FAR, t);
}

// cars of one lane. p: crossing point (2D), dir: travel direction (unit 2D),
// side: unit lateral (2D) pointing from p towards the lane centre, latOff: that distance.
void laneCars(float2 p, float y, float2 dir, float2 side, float latOff, uint laneSeed, float occ,
              float3 ro, float3 rd, float pa, float trans, bool bodies, inout Traffic tr)
{
    float speed = lerp(9.0, 22.0, rndu(laneSeed, 1u));
    float s = dot(p, dir);
    float ph = s - speed * _Time.y;
    float n0 = floor(ph / LANE_SLOT);
    float3 D3 = float3(dir.x, 0, dir.y);
    float3 S3 = float3(-dir.y, 0, dir.x);
    float head = 0.25 + 0.75 * pow(saturate(dot(D3, -rd)), 2.0);
    float tail = 0.25 + 0.75 * pow(saturate(dot(D3,  rd)), 2.0);

    [loop] for (int j = -1; j <= 1; j++)
    {
        float n = n0 + j;
        uint cs = hashU(laneSeed, uint(int(n)));
        if (rndu(cs, 0u) > occ) continue;
        float r = rndu(cs, 3u);
        int kind = r < 0.58 ? CAR_SALOON : (r < 0.78 ? CAR_VAN : (r < 0.89 ? CAR_BUS : CAR_HAULER));
        float3 he = carBounds(kind);
        float sc = (n + 0.25 + 0.5 * rndu(cs, 1u)) * LANE_SLOT + speed * _Time.y;
        float2 c2 = p + dir * (sc - s) + side * latOff;
        float bob = 0.3 * sin(_Time.y * 0.7 + rndu(cs, 2u) * 6.28);
        float3 C = float3(c2.x, y + bob, c2.y);

        if (bodies)
        {
            float3 o = ro - C;
            float te = boxEntry(float3(dot(o, D3), o.y, dot(o, S3)), float3(dot(rd, D3), rd.y, dot(rd, S3)), he);
            if (te < tr.cT && te < CAR_BODY_FAR)
            {
                tr.cT = te; tr.cC = C; tr.cF = D3; tr.cKind = kind; tr.cSeed = cs;
            }
        }

        // lights on the nose and tail
        float lw = he.z * 0.7;
        float ly = kind == CAR_SALOON ? -0.05 : -he.y * 0.45;
        float L = he.x - 0.12;
        float3 wHead = float3(1.0, 0.93, 0.8) * head * _CarIntensity;
        float3 wTail = float3(1.0, 0.04, 0.02) * tail * _CarIntensity * 0.8;
        float rl = kind >= CAR_BUS ? 0.16 : 0.11;
        float lim = tr.bodyT + 0.3;
        float3 acc = 0;
        acc += splatLight(C + D3 * L + S3 * lw + float3(0, ly, 0), wHead, rl, ro, rd, pa, lim);
        acc += splatLight(C + D3 * L - S3 * lw + float3(0, ly, 0), wHead, rl, ro, rd, pa, lim);
        acc += splatLight(C - D3 * L + S3 * lw + float3(0, ly, 0), wTail, rl, ro, rd, pa, lim);
        acc += splatLight(C - D3 * L - S3 * lw + float3(0, ly, 0), wTail, rl, ro, rd, pa, lim);
        tr.light += acc * trans;
    }
}

void trafficAt(float2 p, float y, int level, float tCross, float3 ro, float3 rd, float pa, float trans, inout Traffic tr)
{
    float dens = laneDensity(y);
    bool bodies = tCross < CAR_BODY_FAR + 20.0;
    bool near   = tCross < 120.0;                    // also look at the neighbouring lanes
    Lot L = locateLot(p);
    float2 A[4] = { L.q.a, L.q.b, L.q.c, L.q.d };
    float2 B[4] = { L.q.b, L.q.c, L.q.d, L.q.a };
    float hw[4] = { L.hw.x, L.hw.y, L.hw.z, L.hw.w };
    float best = 1e9; int be = 0;
    [unroll] for (int e = 0; e < 4; e++)
    {
        float d = cross2(normalize(B[e] - A[e]), p - A[e]) - hw[e];   // <0: inside the street half
        if (d < best) { best = d; be = e; }
    }
    float2 Ae = A[be], Be = B[be];
    float2 D = normalize(Be - Ae);
    float dist = cross2(D, p - Ae);              // distance from the street centre line
    float hwb = hw[be];

    if (dist < hwb - 3.0)
    {
        // ---- a street: lanes at (m + 0.5) * LANE_W from the centre line
        float cLine = cross2(D, -Ae);                 // line constant: same for every lot along it
        uint lineId = hash2i(int2(int(round(cLine * 0.25)), int(round(atan2(D.y, D.x) * 40.0))));
        int m0 = int(floor(dist / LANE_W));
        int mA = near ? m0 - 1 : m0, mB = near ? m0 + 1 : m0;
        [loop] for (int m = mA; m <= mB; m++)
        {
            float dm = (m + 0.5) * LANE_W;
            if (m < 0 || dm > hwb - 3.5) continue;
            uint laneSeed = hash3i(int3(int(lineId & 0x7FFFFFFFu), level, m));
            if (rndu(laneSeed, 0u) > dens * 0.32 + 0.02) continue;    // only some strata carry traffic
            // right-hand traffic: on this side cars travel along -D
            laneCars(p, y, -D, perpL(D), dm - dist, laneSeed, 0.08 + 0.22 * dens, ro, rd, pa, trans, bodies, tr);
        }
        return;
    }

    // ---- inside the lot: a sky-street between split stage-1 towers?
    if (lotIsVoid(L.seed)) return;
    Quad F0; float top0;
    stage0(L, F0, top0);
    if (y < top0 + 6.0) return;
    Quad B1; bool split1; float gap1; uint s1;
    if (!stage1(L, F0, B1, split1, gap1, s1) || !split1) return;
    bool uCut; float2 P, Q;
    regionCut(B1, s1, uCut, P, Q);
    float2 Dg = uCut ? normalize(Q - P) : normalize(P - Q);
    float2 Og = uCut ? P : Q;
    float dg = cross2(Dg, p - Og);
    float ad = abs(dg);
    if (ad > gap1 - 1.0) return;
    int m = int(floor(ad / LANE_W));
    float dm = (m + 0.5) * LANE_W;
    if (dm > gap1 - 1.0) return;
    uint laneSeed = hash3i(int3(int(s1 & 0x7FFFFFFFu), level, m * (dg > 0 ? 1 : -1)));
    if (rndu(laneSeed, 0u) > dens * 0.45 + 0.05) return;
    float sgn = dg > 0 ? 1.0 : -1.0;
    laneCars(p, y, -Dg * sgn, perpL(Dg) * sgn, dm - ad, laneSeed, 0.1 + 0.22 * dens, ro, rd, pa, trans, bodies, tr);
}

Traffic traffic(float3 ro, float3 rd, float tHit, float pa)
{
    Traffic tr = (Traffic)0;
    tr.bodyT = 1e9; tr.cT = 1e9;
    if (abs(rd.y) < 1e-4 || _TrafficPlanes <= 0) return tr;
    float dir = rd.y > 0 ? 1.0 : -1.0;
    float k0 = rd.y > 0 ? ceil(ro.y / LANE_DY) : floor(ro.y / LANE_DY);
    [loop] for (int i = 0; i < _TrafficPlanes; i++)
    {
        float k = k0 + dir * i;
        float y = k * LANE_DY;
        if (y > TRAFFIC_TOP) break;
        float t = (y - ro.y) / rd.y;
        if (t > tHit + 30.0) break;
        float trn = fogTrans(ro, rd, t);
        if (trn < 0.004) break;
        float2 p = ro.xz + rd.xz * t;
        trafficAt(p, y, int(k), t, ro, rd, pa, trn, tr);
        if (tr.cT < tHit)
        {
            marchCar(ro, rd, tr);
            if (tr.bodyT < 1e8) break;             // everything further is behind that car
            tr.cT = 1e9;
        }
    }
    if (tr.bodyT > tHit) { tr.bodyT = 1e9; tr.bodyA = 0; }
    return tr;
}

#endif
