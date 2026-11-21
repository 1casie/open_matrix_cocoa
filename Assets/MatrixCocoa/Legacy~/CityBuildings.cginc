// =====================================================================================
//  CityBuildings.cginc - the building on each lot, and the ray tracer.
//
//  A building is a stack of STAGES (prisms over convex quads):
//    stage 0 : the lot minus its streets, from the bottomless depths up to h0.
//    stage 1 : on top of stage 0, set back; ~55% of the time the footprint is SPLIT in
//              two by a sky-street (the divide-and-conquer again, one level up).
//    stage 2 : same again on each child (~45% split).
//    stage 3+: plain set-back towers, each increasingly unlikely.
//  Each stage is 10..100 floors, bimodal (main mode ~30 floors, second ~68).
//  "Titan" lots keep going for up to 8 stages.
//
//  Tracing: the ray walks lot by lot (exact ray/convex-quad exit, no grid), and in each
//  lot only the stages whose height range overlaps the ray's height range are tested.
// =====================================================================================
#ifndef CITY_BUILDINGS_INCLUDED
#define CITY_BUILDINGS_INCLUDED

struct Hit
{
    float t;
    int   face;      // 0..3 wall over quad edge e, 4 roof, 5 soffit (underside), -1 none
    Quad  f;         // footprint of the stage that was hit
    float y0, y1;    // its vertical extent
    uint  seed;      // stage seed
    uint  lotSeed;
    int   stage;
};

Hit noHit(float tMax)
{
    Hit h;
    h.t = tMax; h.face = -1; h.f = (Quad)0; h.y0 = 0; h.y1 = 0;
    h.seed = 0; h.lotSeed = 0; h.stage = 0;
    return h;
}

float stageFloors(uint s, bool titan)
{
    float r = rndu(s, 10u);
    float n = (rndu(s, 11u) + rndu(s, 12u) + rndu(s, 13u) - 1.5) * 2.0;   // ~N(0,1)
    float f = r < (titan ? 0.3 : 0.68) ? 30.0 + n * 6.0 : 68.0 + n * 13.0;
    return clamp(round(f), 10.0, 100.0);
}

// per-edge set-backs for a stage (0 keeps a wall flush, negative = cantilevered overhang)
float4 stageSetbacks(uint s, int stage)
{
    float4 r = float4(rndu(s, 30u), rndu(s, 31u), rndu(s, 32u), rndu(s, 33u));
    float4 k = float4(rndu(s, 34u), rndu(s, 35u), rndu(s, 36u), rndu(s, 37u));
    float4 sb = lerp(3.0, 15.0, r);
    sb = k < 0.3 ? 0.0 : sb;
    if (stage == 1) sb = k > 0.93 ? -4.0 : sb;
    return sb;
}

// child c of q after a split by a sky-street of half-width g
Quad splitChild(Quad q, uint s, int c, float g)
{
    bool uCut; float2 P, Q;
    regionCut(q, s, uCut, P, Q);
    Quad r = q;
    if (uCut)
    {
        if (c == 0) { r.b = P; r.c = Q; r = insetQuad(r, float4(0, g, 0, 0)); }
        else        { r.a = P; r.d = Q; r = insetQuad(r, float4(0, 0, 0, g)); }
    }
    else
    {
        if (c == 0) { r.c = P; r.d = Q; r = insetQuad(r, float4(0, 0, g, 0)); }
        else        { r.a = Q; r.b = P; r = insetQuad(r, float4(g, 0, 0, 0)); }
    }
    return r;
}

// ---------------------------------------------------------------- shared stage generators
// (also used by the traffic code to find sky-streets, so keep them the single source)
bool lotIsVoid(uint s0)  { return rndu(s0, 20u) < VOID_LOT_PROB; }
bool lotIsTitan(uint s0) { return rndu(s0, 21u) < TITAN_PROB; }

void stage0(Lot L, out Quad F0, out float top0)
{
    uint s0 = L.seed;
    float4 extra = float4(rndu(s0, 23u), rndu(s0, 24u), rndu(s0, 25u), rndu(s0, 26u)) * 5.0;
    F0   = insetQuad(L.q, L.hw + extra);
    top0 = stageFloors(s0, lotIsTitan(s0)) * CITY_FLOOR_H;
}

// stage-1 base (before split) + whether it exists/splits
bool stage1(Lot L, Quad F0, out Quad B1, out bool split1, out float gap1, out uint s1)
{
    s1 = hashU(L.seed, 101u);
    B1 = insetQuad(F0, stageSetbacks(s1, 1));
    split1 = rndu(s1, 1u) < 0.55 && quadLongSide(B1) > 90.0;
    gap1 = lerp(6.0, 11.0, rndu(s1, 2u));
    bool titan = lotIsTitan(L.seed);
    return rndu(s1, 0u) < (titan ? 0.99 : 0.8) && quadArea(B1) > 400.0;
}

// ---------------------------------------------------------------- prism intersection
void intersectPrism(float3 ro, float3 rd, Quad f, float y0, float y1,
                    uint seed, uint lotSeed, int stage, inout Hit h)
{
    float tn = -1e9, tf = 1e9; int fn = -1;
    if (abs(rd.y) > 1e-7)
    {
        float ta = (y0 - ro.y) / rd.y, tb = (y1 - ro.y) / rd.y;
        if (ta < tb) { tn = ta; tf = tb; fn = 5; } else { tn = tb; tf = ta; fn = 4; }
    }
    else if (ro.y < y0 || ro.y > y1) return;

    float2 A[4] = { f.a, f.b, f.c, f.d };
    float2 B[4] = { f.b, f.c, f.d, f.a };
    [unroll] for (int e = 0; e < 4; e++)
    {
        float2 E = B[e] - A[e];
        float c0 = cross2(E, ro.xz - A[e]);
        float c1 = cross2(E, rd.xz);
        if (abs(c1) < 1e-9) { if (c0 < 0) return; }
        else
        {
            float te = -c0 / c1;
            if (c1 > 0) { if (te > tn) { tn = te; fn = e; } }
            else tf = min(tf, te);
        }
    }
    if (tn <= tf && tn > 0.0 && tn < h.t)
    {
        h.t = tn; h.face = fn; h.f = f; h.y0 = y0; h.y1 = y1;
        h.seed = seed; h.lotSeed = lotSeed; h.stage = stage;
    }
}

// all stages on lot L for the ray segment [tA, tB]
void intersectLot(Lot L, float3 ro, float3 rd, float tA, float tB, inout Hit h)
{
    uint s0 = L.seed;
    if (lotIsVoid(s0)) return;
    bool titan = lotIsTitan(s0);

    float tEnd = min(tB, h.t);
    float yA = ro.y + rd.y * tA, yB = ro.y + rd.y * tEnd;
    float ylo = min(yA, yB) - 0.01, yhi = max(yA, yB) + 0.01;

    Quad F0; float top0;
    stage0(L, F0, top0);
    if (quadArea(F0) < 200.0) return;            // lot too small for its streets
    if (ylo <= top0) intersectPrism(ro, rd, F0, CITY_DEEP, top0, s0, s0, 0, h);
    if (yhi <= top0) return;

    Quad B1; bool split1; float gap1; uint s1;
    if (!stage1(L, F0, B1, split1, gap1, s1)) return;

    int n1 = split1 ? 2 : 1;
    [loop] for (int c1 = 0; c1 < n1; c1++)
    {
        uint s1c = hashU(s1, 200u + c1);
        Quad F1 = B1;
        if (split1) F1 = splitChild(B1, s1, c1, gap1);
        float top1 = top0 + stageFloors(s1c, titan) * CITY_FLOOR_H;
        if (ylo <= top1) intersectPrism(ro, rd, F1, top0, top1, s1c, s0, 1, h);
        if (yhi <= top1) continue;

        uint s2 = hashU(s1c, 102u);
        if (rndu(s2, 0u) > (titan ? 0.98 : 0.6)) continue;
        Quad B2 = insetQuad(F1, stageSetbacks(s2, 2));
        if (quadArea(B2) < 300.0) continue;
        bool split2 = rndu(s2, 1u) < 0.45 && quadLongSide(B2) > 70.0;
        float gap2 = lerp(5.0, 8.0, rndu(s2, 2u));
        int n2 = split2 ? 2 : 1;
        [loop] for (int c2 = 0; c2 < n2; c2++)
        {
            uint s2c = hashU(s2, 300u + c2);
            Quad F2 = B2;
            if (split2) F2 = splitChild(B2, s2, c2, gap2);
            float top2 = top1 + stageFloors(s2c, titan) * CITY_FLOOR_H;
            if (ylo <= top2) intersectPrism(ro, rd, F2, top1, top2, s2c, s0, 2, h);
            if (yhi <= top2) continue;

            Quad F = F2; float top = top2; uint s = s2c;
            int maxSt = titan ? 8 : 5;
            [loop] for (int st = 3; st < maxSt; st++)
            {
                s = hashU(s, 400u + st);
                float pc = titan ? 0.93 : (st == 3 ? 0.42 : 0.22);
                if (rndu(s, 0u) > pc) break;
                Quad Fn = insetQuad(F, stageSetbacks(s, st));
                if (quadArea(Fn) < 150.0) break;
                float topn = top + stageFloors(s, titan) * CITY_FLOOR_H;
                if (ylo <= topn) intersectPrism(ro, rd, Fn, top, topn, s, s0, st, h);
                if (yhi <= topn) break;
                F = Fn; top = topn;
            }
        }
    }
}

// ---------------------------------------------------------------- the tracer
// Walks the street plan lot by lot. anyHit: stop at the first hit (shadow rays).
Hit traceCity(float3 ro, float3 rd, int maxSteps, float tMax, bool anyHit)
{
    Hit h = noHit(tMax);
    float t = 0.0;
    [loop] for (int i = 0; i < maxSteps; i++)
    {
        float3 p = ro + rd * t;
        if (rd.y > 0.0 && p.y > CITY_MAX_H) break;
        Lot L = locateLot(p.xz);
        float tExit = max(quadExit(L.q, ro.xz, rd.xz), t + 0.05);
        intersectLot(L, ro, rd, t, tExit, h);
        if (h.face >= 0 && (anyHit || h.t <= tExit)) break;
        t = tExit + 0.02 + t * 1e-5;
        if (t >= tMax) break;
    }
    return h;
}

#endif
