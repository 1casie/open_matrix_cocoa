// =====================================================================================
//  CityLayout.cginc - the street plan.
//
//  Level 0: a jittered lattice. Every lattice vertex is a 4-way junction of two
//           continuous (slightly zig-zagging) lines; each row/column line is either a
//           HIGHWAY or a BOULEVARD (fixed per line, so it reads as one long road).
//  Level 1..CITY_MAX_SPLIT: every lattice quad is cut recursively (divide and conquer)
//           by a line joining two opposite edges -> both halves are again convex quads,
//           and the cut meets the old edges in T-junctions (degree 3). No point ever has
//           more than 4 streets meeting -> satisfies the "<= 5 lines per point" rule.
//           Each level is a narrower road class: avenue, street, lane, alley.
//  A LOT is a leaf quad. Its 4 edges are street CENTRE LINES; hw[e] is the half-width
//  of the street on edge e (buildings stand back hw from the centre line).
//
//  Quad convention: a,b,c,d counter-clockwise (seen from above, x right, z up).
//  edge 0 = a->b, 1 = b->c, 2 = c->d, 3 = d->a; the interior is on the LEFT of each edge.
// =====================================================================================
#ifndef CITY_LAYOUT_INCLUDED
#define CITY_LAYOUT_INCLUDED

struct Quad { float2 a, b, c, d; };
struct Lot  { Quad q; float4 hw; uint seed; };

float2 latticeVertex(int2 ij)
{
    uint h = hashU(hash2i(ij), citySeed());
    float2 j = float2(rndu(h, 0u), rndu(h, 1u)) - 0.5;
    return (float2(ij) + j * (2.0 * CITY_JITTER)) * CITY_BLOCK;
}

// Half-width of a whole lattice line (row j or column i). Row 0 is "our" highway.
float lineHalfWidth(int idx, uint salt)
{
    if (idx == 0 && salt == ROW_SALT) return 46.0;
    uint h = hashU(uint(idx) ^ salt, citySeed());
    bool highway = rndu(h, 0u) < 0.33;
    return highway ? lerp(36.0, 52.0, rndu(h, 1u)) : lerp(22.0, 30.0, rndu(h, 1u));
}

// road class widths of the divide-and-conquer cuts
float splitHalfWidth(int lvl, float r)
{
    if (lvl == 1) return lerp(15.0, 20.0, r);   // avenue
    if (lvl == 2) return lerp(10.0, 14.0, r);   // street
    if (lvl == 3) return lerp(7.5, 10.0, r);    // lane
    return lerp(5.5, 7.5, r);                   // alley
}

Quad cellQuad(int2 ij)
{
    Quad q;
    q.a = latticeVertex(ij);
    q.b = latticeVertex(ij + int2(1, 0));
    q.c = latticeVertex(ij + int2(1, 1));
    q.d = latticeVertex(ij + int2(0, 1));
    return q;
}

float sideOf(float2 a, float2 b, float2 p) { return cross2(b - a, p - a); }

int2 locateCell(float2 p)
{
    int2 ij = int2(floor(p / CITY_BLOCK));
    [unroll] for (int it = 0; it < 3; it++)
    {
        Quad q = cellQuad(ij);
        int2 m = int2(0, 0);
        if      (sideOf(q.a, q.b, p) < 0) m.y = -1;
        else if (sideOf(q.c, q.d, p) < 0) m.y =  1;
        if      (sideOf(q.d, q.a, p) < 0) m.x = -1;
        else if (sideOf(q.b, q.c, p) < 0) m.x =  1;
        ij += m;
    }
    return ij;
}

// The cut applied to a region: returns the two endpoints P (first) and Q.
//  uCut = true : P on a->b, Q on d->c  (children: 0 = left (a,P,Q,d), 1 = right (P,b,c,Q))
//  uCut = false: P on b->c, Q on a->d  (children: 0 = bottom (a,b,P,Q), 1 = top (Q,P,c,d))
void regionCut(Quad q, uint seed, out bool uCut, out float2 P, out float2 Q)
{
    float2 eu = (q.b - q.a) + (q.c - q.d);
    float2 ev = (q.d - q.a) + (q.c - q.b);
    uCut = dot(eu, eu) >= dot(ev, ev);
    float t1 = 0.5 + (rndu(seed, 0u) - 0.5) * 0.36;
    float t2 = t1 + (rndu(seed, 1u) - 0.5) * 0.16;
    if (uCut) { P = lerp(q.a, q.b, t1); Q = lerp(q.d, q.c, t2); }
    else      { P = lerp(q.b, q.c, t1); Q = lerp(q.a, q.d, t2); }
}

float quadLongSide(Quad q)
{
    return 0.5 * max(length((q.b - q.a) + (q.c - q.d)), length((q.d - q.a) + (q.c - q.b)));
}
float quadArea(Quad q) { return 0.5 * cross2(q.c - q.a, q.d - q.b); }

Lot locateLot(float2 p)
{
    int2 ij = locateCell(p);
    Lot L;
    L.q  = cellQuad(ij);
    L.hw = float4(lineHalfWidth(ij.y, ROW_SALT), lineHalfWidth(ij.x + 1, COL_SALT),
                  lineHalfWidth(ij.y + 1, ROW_SALT), lineHalfWidth(ij.x, COL_SALT));
    uint seed = hashU(hash2i(ij), citySeed());

    [loop] for (int lvl = 1; lvl <= CITY_MAX_SPLIT; lvl++)
    {
        if (quadLongSide(L.q) < CITY_MIN_SPLIT) break;
        if (lvl >= 3 && rndu(seed, 2u) < 0.16) break;        // occasional mega-lot
        bool uCut; float2 P, Q;
        regionCut(L.q, seed, uCut, P, Q);
        float hwNew = splitHalfWidth(lvl, rndu(seed, 3u));
        bool second;
        if (uCut)
        {
            second = sideOf(P, Q, p) < 0;      // right of P->Q
            if (!second) { L.q.b = P; L.q.c = Q; L.hw.y = hwNew; }
            else         { L.q.a = P; L.q.d = Q; L.hw.w = hwNew; }
        }
        else
        {
            second = sideOf(Q, P, p) > 0;      // left of Q->P = top
            if (!second) { L.q.c = P; L.q.d = Q; L.hw.z = hwNew; }
            else         { L.q.a = Q; L.q.b = P; L.hw.x = hwNew; }
        }
        seed = hashU(seed, second ? 0xB5297A4Du : 0x68E31DA4u);
    }
    L.seed = seed;
    return L;
}

// Absolute ray parameter where the 2D ray o + d t leaves the convex quad.
float quadExit(Quad q, float2 o, float2 d)
{
    float t = 1e9;
    float2 A[4] = { q.a, q.b, q.c, q.d };
    float2 B[4] = { q.b, q.c, q.d, q.a };
    [unroll] for (int e = 0; e < 4; e++)
    {
        float2 E = B[e] - A[e];
        float c1 = cross2(E, d);
        if (c1 < -1e-9) t = min(t, -cross2(E, o - A[e]) / c1);
    }
    return t;
}

// Offset each edge inward by d[e] (negative = outward) and re-intersect neighbours.
float2 lineX(float2 p1, float2 d1, float2 p2, float2 d2)
{
    return p1 + d1 * (cross2(p2 - p1, d2) / cross2(d1, d2));
}
Quad insetQuad(Quad q, float4 d)
{
    float2 D0 = normalize(q.b - q.a), D1 = normalize(q.c - q.b);
    float2 D2 = normalize(q.d - q.c), D3 = normalize(q.a - q.d);
    float2 P0 = q.a + perpL(D0) * d.x, P1 = q.b + perpL(D1) * d.y;
    float2 P2 = q.c + perpL(D2) * d.z, P3 = q.d + perpL(D3) * d.w;
    Quad r;
    r.a = lineX(P3, D3, P0, D0);
    r.b = lineX(P0, D0, P1, D1);
    r.c = lineX(P1, D1, P2, D2);
    r.d = lineX(P2, D2, P3, D3);
    return r;
}

void quadEdge(Quad q, int e, out float2 A, out float2 B)
{
    if      (e == 0) { A = q.a; B = q.b; }
    else if (e == 1) { A = q.b; B = q.c; }
    else if (e == 2) { A = q.c; B = q.d; }
    else             { A = q.d; B = q.a; }
}

// The viewer floats above the middle of the first segment of highway row 0.
float2 cityAnchor() { return 0.5 * (latticeVertex(int2(0, 0)) + latticeVertex(int2(1, 0))); }
float3 worldToCity(float3 w) { float2 a = cityAnchor(); return w + float3(a.x, _AnchorAltitude, a.y); }

#endif
