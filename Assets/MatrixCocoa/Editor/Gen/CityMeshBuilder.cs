using System.Collections.Generic;
using UnityEditor;
using UnityEngine;
using static MatrixCocoa.Gen.CityRules;

namespace MatrixCocoa.Gen
{
    /// <summary>
    /// Turns the rules into meshes (one chunk per lattice cell) and a top-down height map
    /// (used by the facade shader for long sun shadows and canyon occlusion).
    ///
    /// Vertex layout for MatrixCocoa/CityFacade:
    ///   position  world space (city minus the anchor offset)
    ///   normal    outward
    ///   uv0       walls: (u along the wall m, wall length, stage y0, stage y1)   [city metres]
    ///             roofs/soffits: (distance to the footprint edge, 0, y0, y1)
    ///   uv1       (lot seed & 0xFFFFFF, stage seed & 0xFFFFFF, stage, face 0..3 wall / 4 roof / 5 soffit)
    /// </summary>
    public static class CityMeshBuilder
    {
        public static float AnchorAltitude => CityRules.Site.altitude;   // city altitude of world y = 0 (the station roof)
        public const float Radius = 5200f;           // build buildings this far from the viewer
        public const float StationRoofSink = 1.32f;  // lobby slab bottom is at y = -1.3 (the pit and car channels go down to -1.0)
        public const int HeightRes = 2048;
        public const float HeightSize = 10240f;      // metres covered by the height map

        public static Vector3 CityOffset
        {
            get { var a = Anchor; return new Vector3(a.x, AnchorAltitude, a.y); }   // city = world + offset
        }

        class MeshAcc
        {
            public readonly List<Vector3> v = new List<Vector3>();
            public readonly List<Vector3> n = new List<Vector3>();
            public readonly List<Vector4> uv0 = new List<Vector4>();
            public readonly List<Vector4> uv1 = new List<Vector4>();
            public readonly List<int> idx = new List<int>();
        }

        public struct Result
        {
            public List<Mesh> chunks;
            public Texture2D heightMap;
            public Vector4 heightRect;   // (minX, minZ, size, 1/size) in city metres
            public int prisms, lots;
        }

        public static Result Build()
        {
            var res = new Result { chunks = new List<Mesh>() };
            Vector2 anchor = Anchor;
            Vector3 off = CityOffset;
            int r = Mathf.CeilToInt(Radius / Block) + 1;
            int ci = Mathf.FloorToInt(anchor.x / Block), cj = Mathf.FloorToInt(anchor.y / Block);

            var lots = new List<Lot>();
            var prisms = new List<Prism>();
            float hmMinX = anchor.x - HeightSize / 2, hmMinZ = anchor.y - HeightSize / 2;
            var heights = new float[HeightRes * HeightRes];
            for (int k = 0; k < heights.Length; k++) heights[k] = Deep;

            for (int j = cj - r; j <= cj + r; j++)
            for (int i = ci - r; i <= ci + r; i++)
            {
                lots.Clear(); prisms.Clear();
                CellLots(i, j, lots);
                foreach (var L in lots)
                {
                    if ((L.q.Centre - anchor).magnitude > Radius) continue;
                    LotBuilding(L, prisms);
                    res.lots++;
                }
                if (prisms.Count == 0) continue;
                var acc = new MeshAcc();
                foreach (var p0 in prisms)
                {
                    var p = p0;
                    // the lobby's floor slab sits on the station roof: drop the roof under the slab, or the
                    // snowy roof z-fights with the floor (world y = 0 stays at the original roof altitude)
                    if (p.seed == Site.prismSeed && Mathf.Abs(p.y1 - Site.altitude) < 0.01f) p.y1 -= StationRoofSink;
                    AddPrism(acc, p, off); Rasterise(heights, p, hmMinX, hmMinZ);
                }
                res.prisms += prisms.Count;
                var m = new Mesh { name = $"city_{i}_{j}", indexFormat = UnityEngine.Rendering.IndexFormat.UInt32 };
                m.SetVertices(acc.v); m.SetNormals(acc.n);
                m.SetUVs(0, acc.uv0); m.SetUVs(1, acc.uv1);
                m.SetTriangles(acc.idx, 0);
                m.RecalculateBounds();
                res.chunks.Add(m);
            }

            var tex = new Texture2D(HeightRes, HeightRes, TextureFormat.RHalf, false, true)
            {
                name = "CityHeight", wrapMode = TextureWrapMode.Clamp, filterMode = FilterMode.Point,
            };
            var px = new Color[heights.Length];
            for (int k = 0; k < px.Length; k++) px[k] = new Color(heights[k], 0, 0, 0);
            tex.SetPixels(px);
            tex.Apply(false, false);
            res.heightMap = tex;
            res.heightRect = new Vector4(hmMinX, hmMinZ, HeightSize, 1f / HeightSize);
            return res;
        }

        static float Seed24(uint s) => s & 0xFFFFFFu;

        static void AddPrism(MeshAcc m, Prism p, Vector3 off)
        {
            float sl = Seed24(p.lotSeed), ss = Seed24(p.seed);
            // walls
            for (int e = 0; e < 4; e++)
            {
                Vector2 A = p.f[e], B = p.f[(e + 1) & 3];
                Vector2 D = B - A; float len = D.magnitude; D /= len;
                var nrm = new Vector3(D.y, 0, -D.x);
                int b = m.v.Count;
                m.v.Add(W(A, p.y0, off)); m.v.Add(W(B, p.y0, off)); m.v.Add(W(B, p.y1, off)); m.v.Add(W(A, p.y1, off));
                for (int k = 0; k < 4; k++) { m.n.Add(nrm); m.uv1.Add(new Vector4(sl, ss, p.stage, e)); }
                m.uv0.Add(new Vector4(0, len, p.y0, p.y1)); m.uv0.Add(new Vector4(len, len, p.y0, p.y1));
                m.uv0.Add(new Vector4(len, len, p.y0, p.y1)); m.uv0.Add(new Vector4(0, len, p.y0, p.y1));
                // Unity is clockwise-front: seen from outside (along -nrm) A,B,top-B,top-A runs clockwise
                m.idx.AddRange(new[] { b, b + 2, b + 1, b, b + 3, b + 2 });
            }
            // roof: a fan around the centre so uv0.x interpolates to the distance from each edge
            AddCap(m, p, off, p.y1, true, sl, ss);
            if (p.stage > 0) AddCap(m, p, off, p.y0, false, sl, ss);
        }

        static void AddCap(MeshAcc m, Prism p, Vector3 off, float y, bool up, float sl, float ss)
        {
            Vector2 c = p.f.Centre;
            float inr = float.MaxValue;
            for (int e = 0; e < 4; e++)
            {
                Vector2 A = p.f[e], B = p.f[(e + 1) & 3];
                Vector2 D = (B - A).normalized;
                inr = Mathf.Min(inr, D.x * (c.y - A.y) - D.y * (c.x - A.x));
            }
            int b = m.v.Count;
            var nrm = up ? Vector3.up : Vector3.down;
            m.v.Add(W(c, y, off)); m.uv0.Add(new Vector4(Mathf.Max(inr, 0), 0, p.y0, p.y1));
            for (int e = 0; e < 4; e++) { m.v.Add(W(p.f[e], y, off)); m.uv0.Add(new Vector4(0, 0, p.y0, p.y1)); }
            for (int k = 0; k < 5; k++) { m.n.Add(nrm); m.uv1.Add(new Vector4(sl, ss, p.stage, up ? 4 : 5)); }
            for (int e = 0; e < 4; e++)
            {
                int i0 = b + 1 + e, i1 = b + 1 + ((e + 1) & 3);
                // CCW footprint seen from above -> clockwise needs reversed order for an up-facing cap
                if (up) m.idx.AddRange(new[] { b, i1, i0 });
                else    m.idx.AddRange(new[] { b, i0, i1 });
            }
        }

        static Vector3 W(Vector2 xz, float y, Vector3 off) => new Vector3(xz.x - off.x, y - off.y, xz.y - off.z);

        static void Rasterise(float[] h, Prism p, float minX, float minZ)
        {
            float cell = HeightSize / HeightRes;
            float x0 = Mathf.Min(Mathf.Min(p.f.a.x, p.f.b.x), Mathf.Min(p.f.c.x, p.f.d.x));
            float x1 = Mathf.Max(Mathf.Max(p.f.a.x, p.f.b.x), Mathf.Max(p.f.c.x, p.f.d.x));
            float z0 = Mathf.Min(Mathf.Min(p.f.a.y, p.f.b.y), Mathf.Min(p.f.c.y, p.f.d.y));
            float z1 = Mathf.Max(Mathf.Max(p.f.a.y, p.f.b.y), Mathf.Max(p.f.c.y, p.f.d.y));
            int ix0 = Mathf.Max(0, Mathf.FloorToInt((x0 - minX) / cell)), ix1 = Mathf.Min(HeightRes - 1, Mathf.FloorToInt((x1 - minX) / cell));
            int iz0 = Mathf.Max(0, Mathf.FloorToInt((z0 - minZ) / cell)), iz1 = Mathf.Min(HeightRes - 1, Mathf.FloorToInt((z1 - minZ) / cell));
            for (int z = iz0; z <= iz1; z++)
            for (int x = ix0; x <= ix1; x++)
            {
                var q = new Vector2(minX + (x + 0.5f) * cell, minZ + (z + 0.5f) * cell);
                bool inside = true;
                for (int e = 0; e < 4 && inside; e++)
                {
                    Vector2 A = p.f[e], B = p.f[(e + 1) & 3];
                    if ((B.x - A.x) * (q.y - A.y) - (B.y - A.y) * (q.x - A.x) < 0) inside = false;
                }
                if (!inside) continue;
                int k = z * HeightRes + x;
                if (p.y1 > h[k]) h[k] = p.y1;
            }
        }
    }
}
