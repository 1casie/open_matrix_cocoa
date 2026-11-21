using System.Collections.Generic;
using UnityEngine;

namespace MatrixCocoa.Gen
{
    // =====================================================================================
    //  The city's generative rules - the single source of truth for streets and buildings.
    //  (Ported from the original ray-traced shader; hashes are bit-identical integer PCG.)
    //
    //  STREETS  A jittered lattice (Block m). Every row/column line is a HIGHWAY or a
    //           BOULEVARD for its whole length (row 0 is the viewer's highway). Each lattice
    //           quad is then cut recursively (divide and conquer) by lines joining two opposite
    //           edges: avenue, street, lane, alley. All regions stay convex quads; cuts meet
    //           old roads in T-junctions, so no point joins more than 4 roads.
    //  LOTS     Leaf quads. Their edges are street CENTRE lines; hw[e] = street half-width.
    //  STAGES   Each lot grows a stack of prisms: stage 0 from the bottomless depths; stage
    //           1 and 2 set back and sometimes split by a sky-street; 3+ plain set-backs.
    //           10..100 floors each, bimodal (~30 / ~68). Titans keep going.
    //
    //  Quad convention: a,b,c,d counter-clockwise seen from above (x right, z up);
    //  edge 0 = a->b, 1 = b->c, 2 = c->d, 3 = d->a; interior on the LEFT of each edge.
    // =====================================================================================
    public static class CityRules
    {
        // ---------------------------------------------------------------- tunables
        public const float Block = 720f;        // lattice spacing (m)
        public const float Jitter = 0.17f;      // lattice vertex jitter (fraction of Block; < 0.25 keeps quads convex)
        public const int MaxSplit = 5;          // divide-and-conquer depth inside a lattice block
        public const float MinSplit = 170f;     // regions shorter than this are not cut
        public const float FloorH = 3.4f;       // storey height
        public const float Deep = -2600f;       // stage-0 foundations end here (deep in the fog)
        public const float VoidLotProb = 0.045f;
        public const float TitanProb = 0.022f;
        public const uint RowSalt = 0x2C1B3C6Du, ColSalt = 0x297A2D39u;

        public static uint Seed = 7;            // the city seed

        // ---------------------------------------------------------------- hashing
        public static uint Pcg(uint v)
        {
            unchecked
            {
                uint s = v * 747796405u + 2891336453u;
                uint w = ((s >> (int)((s >> 28) + 4u)) ^ s) * 277803737u;
                return (w >> 22) ^ w;
            }
        }
        public static uint HashU(uint a, uint b) { unchecked { return Pcg(a ^ Pcg(b + 0x9E3779B9u)); } }
        public static uint Hash2i(int x, int y) { unchecked { return Pcg((uint)x + Pcg((uint)y + 0x85EBCA6Bu)); } }
        public static uint Hash3i(int x, int y, int z) { unchecked { return Pcg((uint)x + Pcg((uint)y + Pcg((uint)z + 0xC2B2AE35u))); } }
        public static float Rnd(uint seed, uint k) { unchecked { return (Pcg(seed + k * 0x9E3779B9u) >> 8) * (1f / 16777216f); } }
        static uint CitySeed() { unchecked { return Seed * 0x01000193u + 0x811C9DC5u; } }

        static float Cross(Vector2 a, Vector2 b) => a.x * b.y - a.y * b.x;
        static Vector2 PerpL(Vector2 d) => new Vector2(-d.y, d.x);
        static float Side(Vector2 a, Vector2 b, Vector2 p) => Cross(b - a, p - a);

        // ---------------------------------------------------------------- types
        public struct Quad
        {
            public Vector2 a, b, c, d;
            public Vector2 this[int i] => i == 0 ? a : i == 1 ? b : i == 2 ? c : d;
            public float Area => 0.5f * Cross(c - a, d - b);
            public float LongSide => 0.5f * Mathf.Max(((b - a) + (c - d)).magnitude, ((d - a) + (c - b)).magnitude);
            public Vector2 Centre => (a + b + c + d) * 0.25f;
        }
        public struct Lot { public Quad q; public Vector4 hw; public uint seed; public int depth; }
        public struct Prism { public Quad f; public float y0, y1; public uint seed, lotSeed; public int stage; }
        /// <summary>A straight street piece: centre line A->B, half-width, road class (0 highway .. 5 alley).</summary>
        public struct Street { public Vector2 A, B; public float hw; public int cls; public uint id; }
        /// <summary>A sky-street between split stage-1 towers: centre line, half-width, from altitude.</summary>
        public struct SkyStreet { public Vector2 A, B; public float hw; public float yMin; public uint id; }

        // ---------------------------------------------------------------- street plan
        public static Vector2 LatticeVertex(int i, int j)
        {
            uint h = HashU(Hash2i(i, j), CitySeed());
            var jt = new Vector2(Rnd(h, 0u), Rnd(h, 1u)) - new Vector2(0.5f, 0.5f);
            return (new Vector2(i, j) + jt * (2f * Jitter)) * Block;
        }

        public static float LineHalfWidth(int idx, uint salt, out bool highway)
        {
            highway = true;
            if (idx == 0 && salt == RowSalt) return 46f;
            uint h = HashU(unchecked((uint)idx) ^ salt, CitySeed());
            highway = Rnd(h, 0u) < 0.33f;
            return highway ? Mathf.Lerp(36f, 52f, Rnd(h, 1u)) : Mathf.Lerp(22f, 30f, Rnd(h, 1u));
        }
        public static float LineHalfWidth(int idx, uint salt) => LineHalfWidth(idx, salt, out _);

        public static float SplitHalfWidth(int lvl, float r)
        {
            if (lvl == 1) return Mathf.Lerp(15f, 20f, r);
            if (lvl == 2) return Mathf.Lerp(10f, 14f, r);
            if (lvl == 3) return Mathf.Lerp(7.5f, 10f, r);
            return Mathf.Lerp(5.5f, 7.5f, r);
        }

        public static Quad CellQuad(int i, int j) => new Quad
        {
            a = LatticeVertex(i, j), b = LatticeVertex(i + 1, j),
            c = LatticeVertex(i + 1, j + 1), d = LatticeVertex(i, j + 1),
        };

        public static void RegionCut(Quad q, uint seed, out bool uCut, out Vector2 P, out Vector2 Q)
        {
            Vector2 eu = (q.b - q.a) + (q.c - q.d), ev = (q.d - q.a) + (q.c - q.b);
            uCut = eu.sqrMagnitude >= ev.sqrMagnitude;
            float t1 = 0.5f + (Rnd(seed, 0u) - 0.5f) * 0.36f;
            float t2 = t1 + (Rnd(seed, 1u) - 0.5f) * 0.16f;
            if (uCut) { P = Vector2.Lerp(q.a, q.b, t1); Q = Vector2.Lerp(q.d, q.c, t2); }
            else      { P = Vector2.Lerp(q.b, q.c, t1); Q = Vector2.Lerp(q.a, q.d, t2); }
        }

        /// <summary>All lots of lattice cell (i, j), plus the internal street cuts.</summary>
        public static void CellLots(int i, int j, List<Lot> lots, List<Street> cuts = null)
        {
            var root = new Lot
            {
                q = CellQuad(i, j),
                hw = new Vector4(LineHalfWidth(j, RowSalt), LineHalfWidth(i + 1, ColSalt), LineHalfWidth(j + 1, RowSalt), LineHalfWidth(i, ColSalt)),
                seed = HashU(Hash2i(i, j), CitySeed()),
            };
            Split(root, 1, lots, cuts);
        }

        static void Split(Lot L, int lvl, List<Lot> lots, List<Street> cuts)
        {
            uint seed = L.seed;
            if (lvl > MaxSplit || L.q.LongSide < MinSplit || (lvl >= 3 && Rnd(seed, 2u) < 0.16f))
            {
                L.depth = lvl - 1;
                lots.Add(L);
                return;
            }
            RegionCut(L.q, seed, out bool uCut, out Vector2 P, out Vector2 Q);
            float hwNew = SplitHalfWidth(lvl, Rnd(seed, 3u));
            if (cuts != null) cuts.Add(new Street { A = P, B = Q, hw = hwNew, cls = 1 + lvl, id = HashU(seed, 0x51u) });
            Lot first = L, second = L;
            if (uCut)
            {
                first.q.b = P; first.q.c = Q; first.hw.y = hwNew;
                second.q.a = P; second.q.d = Q; second.hw.w = hwNew;
            }
            else
            {
                first.q.c = P; first.q.d = Q; first.hw.z = hwNew;
                second.q.a = Q; second.q.b = P; second.hw.x = hwNew;
            }
            first.seed = HashU(seed, 0x68E31DA4u);
            second.seed = HashU(seed, 0xB5297A4Du);
            Split(first, lvl + 1, lots, cuts);
            Split(second, lvl + 1, lots, cuts);
        }

        /// <summary>The lattice street segments bounding cell (i, j): bottom (row j) and left (column i).</summary>
        public static void CellLatticeStreets(int i, int j, List<Street> streets)
        {
            var q = CellQuad(i, j);
            float hwRow = LineHalfWidth(j, RowSalt, out bool hr);
            float hwCol = LineHalfWidth(i, ColSalt, out bool hc);
            streets.Add(new Street { A = q.a, B = q.b, hw = hwRow, cls = hr ? 0 : 1, id = Hash3i(i, j, 1) });
            streets.Add(new Street { A = q.d, B = q.a, hw = hwCol, cls = hc ? 0 : 1, id = Hash3i(i, j, 2) });
        }

        // ---------------------------------------------------------------- geometry helpers
        static Vector2 LineX(Vector2 p1, Vector2 d1, Vector2 p2, Vector2 d2) => p1 + d1 * (Cross(p2 - p1, d2) / Cross(d1, d2));

        public static Quad Inset(Quad q, Vector4 d)
        {
            Vector2 D0 = (q.b - q.a).normalized, D1 = (q.c - q.b).normalized, D2 = (q.d - q.c).normalized, D3 = (q.a - q.d).normalized;
            Vector2 P0 = q.a + PerpL(D0) * d.x, P1 = q.b + PerpL(D1) * d.y, P2 = q.c + PerpL(D2) * d.z, P3 = q.d + PerpL(D3) * d.w;
            return new Quad { a = LineX(P3, D3, P0, D0), b = LineX(P0, D0, P1, D1), c = LineX(P1, D1, P2, D2), d = LineX(P2, D2, P3, D3) };
        }

        // ---------------------------------------------------------------- buildings
        public static float StageFloors(uint s, bool titan)
        {
            float r = Rnd(s, 10u);
            float n = (Rnd(s, 11u) + Rnd(s, 12u) + Rnd(s, 13u) - 1.5f) * 2f;
            float f = r < (titan ? 0.3f : 0.68f) ? 30f + n * 6f : 68f + n * 13f;
            return Mathf.Clamp(Mathf.Round(f), 10f, 100f);
        }

        public static Vector4 StageSetbacks(uint s, int stage)
        {
            float Sb(uint kr, uint kk)
            {
                float r = Rnd(s, kr), k = Rnd(s, kk);
                float v = Mathf.Lerp(3f, 15f, r);
                if (k < 0.3f) v = 0f;
                if (stage == 1 && k > 0.93f) v = -4f;
                return v;
            }
            return new Vector4(Sb(30u, 34u), Sb(31u, 35u), Sb(32u, 36u), Sb(33u, 37u));
        }

        static Quad SplitChild(Quad q, uint s, int c, float g)
        {
            RegionCut(q, s, out bool uCut, out Vector2 P, out Vector2 Q);
            Quad r = q;
            if (uCut)
            {
                if (c == 0) { r.b = P; r.c = Q; r = Inset(r, new Vector4(0, g, 0, 0)); }
                else        { r.a = P; r.d = Q; r = Inset(r, new Vector4(0, 0, 0, g)); }
            }
            else
            {
                if (c == 0) { r.c = P; r.d = Q; r = Inset(r, new Vector4(0, 0, g, 0)); }
                else        { r.a = Q; r.b = P; r = Inset(r, new Vector4(g, 0, 0, 0)); }
            }
            return r;
        }

        public static bool IsVoid(uint s0) => Rnd(s0, 20u) < VoidLotProb;
        public static bool IsTitan(uint s0) => Rnd(s0, 21u) < TitanProb;

        /// <summary>All stage prisms of a lot (and the sky-streets between split towers).</summary>
        public static void LotBuilding(Lot L, List<Prism> prisms, List<SkyStreet> sky = null)
        {
            uint s0 = L.seed;
            if (IsVoid(s0)) return;
            bool titan = IsTitan(s0);

            var extra = new Vector4(Rnd(s0, 23u), Rnd(s0, 24u), Rnd(s0, 25u), Rnd(s0, 26u)) * 5f;
            Quad F0 = Inset(L.q, L.hw + extra);
            if (F0.Area < 200f) return;
            float top0 = StageFloors(s0, titan) * FloorH;
            prisms.Add(new Prism { f = F0, y0 = Deep, y1 = top0, seed = s0, lotSeed = s0, stage = 0 });

            uint s1 = HashU(s0, 101u);
            Quad B1 = Inset(F0, StageSetbacks(s1, 1));
            bool split1 = Rnd(s1, 1u) < 0.55f && B1.LongSide > 90f;
            float gap1 = Mathf.Lerp(6f, 11f, Rnd(s1, 2u));
            if (!(Rnd(s1, 0u) < (titan ? 0.99f : 0.8f) && B1.Area > 400f)) return;
            if (split1 && sky != null)
            {
                RegionCut(B1, s1, out bool uc, out Vector2 P, out Vector2 Q);
                sky.Add(new SkyStreet { A = uc ? P : Q, B = uc ? Q : P, hw = gap1, yMin = top0 + 6f, id = s1 });
            }

            int n1 = split1 ? 2 : 1;
            for (int c1 = 0; c1 < n1; c1++)
            {
                uint s1c = HashU(s1, 200u + (uint)c1);
                Quad F1 = split1 ? SplitChild(B1, s1, c1, gap1) : B1;
                float top1 = top0 + StageFloors(s1c, titan) * FloorH;
                prisms.Add(new Prism { f = F1, y0 = top0, y1 = top1, seed = s1c, lotSeed = s0, stage = 1 });

                uint s2 = HashU(s1c, 102u);
                if (Rnd(s2, 0u) > (titan ? 0.98f : 0.6f)) continue;
                Quad B2 = Inset(F1, StageSetbacks(s2, 2));
                if (B2.Area < 300f) continue;
                bool split2 = Rnd(s2, 1u) < 0.45f && B2.LongSide > 70f;
                float gap2 = Mathf.Lerp(5f, 8f, Rnd(s2, 2u));
                int n2 = split2 ? 2 : 1;
                for (int c2 = 0; c2 < n2; c2++)
                {
                    uint s2c = HashU(s2, 300u + (uint)c2);
                    Quad F2 = split2 ? SplitChild(B2, s2, c2, gap2) : B2;
                    float top2 = top1 + StageFloors(s2c, titan) * FloorH;
                    prisms.Add(new Prism { f = F2, y0 = top1, y1 = top2, seed = s2c, lotSeed = s0, stage = 2 });

                    Quad F = F2; float top = top2; uint s = s2c;
                    int maxSt = titan ? 8 : 5;
                    for (int st = 3; st < maxSt; st++)
                    {
                        s = HashU(s, 400u + (uint)st);
                        float pc = titan ? 0.93f : (st == 3 ? 0.42f : 0.22f);
                        if (Rnd(s, 0u) > pc) break;
                        Quad Fn = Inset(F, StageSetbacks(s, st));
                        if (Fn.Area < 150f) break;
                        float topn = top + StageFloors(s, titan) * FloorH;
                        prisms.Add(new Prism { f = Fn, y0 = top, y1 = topn, seed = s, lotSeed = s0, stage = st });
                        F = Fn; top = topn;
                    }
                }
            }
        }

        // ---------------------------------------------------------------- the station site
        /// <summary>
        /// Where the spawn station stands: a top-stage roof near the start of highway row 0, with a
        /// long edge facing a wide street. World origin = that edge's midpoint (0.5 m inside the
        /// facade) at roof height; +Z of the station = the edge's outward normal (towards the street).
        /// </summary>
        public struct SiteInfo
        {
            public Vector2 anchor;      // city xz of the world origin
            public float altitude;      // city y of the world origin (the roof)
            public Vector2 normal;      // outward edge normal (xz)
            public float edgeLength, depth, streetHalfWidth;
            public uint prismSeed;
        }

        public const float StationMinEdge = 62f, StationMinDepth = 28f;

        static SiteInfo? site;
        static uint siteFor = uint.MaxValue;
        public static SiteInfo Site
        {
            get
            {
                if (site == null || siteFor != Seed) { site = PickSite(); siteFor = Seed; }
                return site.Value;
            }
        }

        static SiteInfo PickSite()
        {
            Vector2 centre = 0.5f * (LatticeVertex(0, 0) + LatticeVertex(1, 0));   // our highway
            var lots = new List<Lot>(); var prisms = new List<Prism>();
            SiteInfo best = default; float bestScore = float.MinValue;
            for (int j = -1; j <= 0; j++)
            for (int i = -1; i <= 1; i++)
            {
                lots.Clear(); CellLots(i, j, lots);
                foreach (var L in lots)
                {
                    prisms.Clear(); LotBuilding(L, prisms);
                    foreach (var p in prisms)
                    {
                        if (p.y1 < 170f || p.y1 > 330f) continue;
                        bool topped = false;
                        foreach (var q in prisms) if (Mathf.Abs(q.y0 - p.y1) < 0.01f) { topped = true; break; }
                        if (topped) continue;
                        for (int e = 0; e < 4; e++)
                        {
                            Vector2 A = p.f[e], B = p.f[(e + 1) & 3];
                            float len = (B - A).magnitude;
                            if (len < StationMinEdge) continue;
                            Vector2 D = (B - A) / len, N = new Vector2(D.y, -D.x);
                            float depth = float.MaxValue;
                            for (int k = 0; k < 4; k++) depth = Mathf.Min(depth, k == e || k == ((e + 1) & 3) ? float.MaxValue : Vector2.Dot(A - p.f[k], N));
                            if (depth < StationMinDepth) continue;
                            Vector2 mid = 0.5f * (A + B);
                            float hw = L.hw[e];
                            float score = hw * 2f - Mathf.Abs(p.y1 - 240f) * 0.3f - (mid - centre).magnitude * 0.02f;
                            if (score <= bestScore) continue;
                            bestScore = score;
                            best = new SiteInfo
                            {
                                anchor = mid - N * 0.5f, altitude = p.y1, normal = N,
                                edgeLength = len, depth = depth, streetHalfWidth = hw, prismSeed = p.seed,
                            };
                        }
                    }
                }
            }
            if (bestScore == float.MinValue) Debug.LogError("[MatrixCocoa] no station site found near the highway - try another CityRules.Seed");
            return best;
        }

        /// <summary>City xz of the world origin (the station).</summary>
        public static Vector2 Anchor => Site.anchor;
    }
}
