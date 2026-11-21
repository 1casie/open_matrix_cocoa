using System.Collections.Generic;
using UnityEngine;
using static MatrixCocoa.Gen.CityRules;

namespace MatrixCocoa.Gen
{
    /// <summary>
    /// Floating traffic. Cars fly in strata every LaneDY metres along every street (and along
    /// the sky-streets between split towers, above the stage-0 roofs). Only some strata of a
    /// street carry traffic and density falls with altitude, so looking down you see layered
    /// rivers of white and red that thicken into the depths.
    ///
    /// Each car is baked once with its lane (start, direction, length, altitude, speed, phase);
    /// MatrixCocoa/CityCar* shaders move it along the lane every frame (wrapping at the end,
    /// shrinking in/out over the last metres). Two meshes:
    ///   lights - every car within TrafficRadius: two glare quads (head / tail lamps)
    ///   bodies - only lanes within BodyRadius: sleek lofted hulls, 4 kinds
    ///
    /// Vertex layout (both): uv0 = (lane start x, z, dir x, z) world; uv1 = (altitude world,
    /// lane length, speed, phase); uv2 = (kind, paint, seed01, -).
    /// lights: position = (corner x, corner y, 1 head / 0 tail); bodies: position/normal in car space.
    /// </summary>
    public static class CityTrafficBuilder
    {
        public const float LaneDY = 16f, LaneW = 4.5f, Slot = 34f;
        public const float TrafficRadius = 1350f, BodyRadius = 380f;
        public const float YMin = -900f, YMax = 1100f;

        public const int Saloon = 0, Van = 1, Bus = 2, Hauler = 3;
        // half-length, half-width, lamp height (car space) per kind
        public static readonly Vector3[] Dims =
        {
            new Vector3(2.4f, 0.92f, -0.02f),
            new Vector3(2.6f, 1.02f, -0.4f),
            new Vector3(5.6f, 1.2f, -0.55f),
            new Vector3(6.3f, 1.3f, -0.7f),
        };

        static float Density(float y) => y < 0 ? 0.85f : 0.85f * Mathf.Exp(-y / 300f);

        struct Lane { public Vector2 A, D; public float len, y, speed; public uint seed; public float occ; }

        public struct Result { public List<Mesh> lights, bodies; public int cars, bodyCars; }

        public static Result Build()
        {
            Vector2 anchor = Anchor;
            Vector3 off = CityMeshBuilder.CityOffset;
            var viewer = new Vector3(anchor.x, CityMeshBuilder.AnchorAltitude, anchor.y);
            int r = Mathf.CeilToInt(TrafficRadius / Block) + 1;
            int ci = Mathf.FloorToInt(anchor.x / Block), cj = Mathf.FloorToInt(anchor.y / Block);

            var streets = new List<Street>();
            var sky = new List<SkyStreet>();
            var lots = new List<Lot>();
            var prisms = new List<Prism>();
            for (int j = cj - r; j <= cj + r; j++)
            for (int i = ci - r; i <= ci + r; i++)
            {
                CellLatticeStreets(i, j, streets);
                lots.Clear();
                CellLots(i, j, lots, streets);
                foreach (var L in lots) { prisms.Clear(); LotBuilding(L, prisms, sky); }
            }

            var lanes = new List<Lane>();
            foreach (var s in streets) AddLanes(lanes, s.A, s.B, s.hw - 3.5f, s.id, YMin, 0.32f, 0.02f, viewer);
            foreach (var s in sky) AddLanes(lanes, s.A, s.B, s.hw - 1f, s.id, Mathf.Max(s.yMin, YMin), 0.45f, 0.05f, viewer);

            var res = new Result { lights = new List<Mesh>(), bodies = new List<Mesh>() };
            var hulls = new Mesh[4];
            for (int k = 0; k < 4; k++) hulls[k] = CarHull.Build(k);

            var la = new Acc(); var ba = new Acc();
            foreach (var lane in lanes)
            {
                int slots = Mathf.FloorToInt(lane.len / Slot);
                bool bodies = SegDist(viewer, lane) < BodyRadius;
                for (int n = 0; n < slots; n++)
                {
                    uint cs = HashU(lane.seed, (uint)n);
                    if (Rnd(cs, 0u) > lane.occ) continue;
                    float rk = Rnd(cs, 3u);
                    int kind = rk < 0.58f ? Saloon : rk < 0.78f ? Van : rk < 0.89f ? Bus : Hauler;
                    float phase = (n + 0.25f + 0.5f * Rnd(cs, 1u)) * Slot;
                    var u0 = new Vector4(lane.A.x - off.x, lane.A.y - off.z, lane.D.x, lane.D.y);
                    var u1 = new Vector4(lane.y - off.y, lane.len, lane.speed, phase);
                    var u2 = new Vector4(kind, Pcg(cs) & 7u, Rnd(cs, 2u), 0);
                    AddLights(la, u0, u1, u2);
                    res.cars++;
                    if (bodies) { AddBody(ba, hulls[kind], u0, u1, u2); res.bodyCars++; }
                    if (la.v.Count > 600000) res.lights.Add(la.ToMesh("traffic_lights"));
                    if (ba.v.Count > 600000) res.bodies.Add(ba.ToMesh("traffic_bodies"));
                }
            }
            if (la.v.Count > 0) res.lights.Add(la.ToMesh("traffic_lights"));
            if (ba.v.Count > 0) res.bodies.Add(ba.ToMesh("traffic_bodies"));
            foreach (var h in hulls) Object.DestroyImmediate(h);
            return res;
        }

        static void AddLanes(List<Lane> lanes, Vector2 A, Vector2 B, float usable, uint id, float yFrom, float pOn, float pBase, Vector3 viewer)
        {
            Vector2 D = (B - A); float len = D.magnitude;
            if (len < Slot * 2) return;
            D /= len;
            Vector2 left = new Vector2(-D.y, D.x);
            int kmin = Mathf.CeilToInt(yFrom / LaneDY), kmax = Mathf.FloorToInt(YMax / LaneDY);
            for (int side = -1; side <= 1; side += 2)
            for (int m = 0; (m + 0.5f) * LaneW <= usable; m++)
            {
                float dm = (m + 0.5f) * LaneW;
                // right-hand traffic: the lanes left of A->B travel B->A
                Vector2 dir = side > 0 ? -D : D;
                Vector2 start = (side > 0 ? B : A) + left * (side * dm);
                for (int k = kmin; k <= kmax; k++)
                {
                    float y = k * LaneDY;
                    uint ls = Hash3i((int)(id & 0x7FFFFFFF), k, m * side);
                    float dens = Density(y);
                    if (Rnd(ls, 0u) > dens * pOn + pBase) continue;
                    var lane = new Lane
                    {
                        A = start, D = dir, len = len, y = y, seed = ls,
                        speed = Mathf.Lerp(9f, 22f, Rnd(ls, 1u)), occ = 0.06f + 0.17f * dens,
                    };
                    if (SegDist(viewer, lane) > TrafficRadius) continue;
                    lanes.Add(lane);
                }
            }
        }

        static float SegDist(Vector3 p, Lane l)
        {
            var a = new Vector3(l.A.x, l.y, l.A.y);
            var d = new Vector3(l.D.x, 0, l.D.y);
            float t = Mathf.Clamp(Vector3.Dot(p - a, d), 0, l.len);
            return (a + d * t - p).magnitude;
        }

        class Acc
        {
            public List<Vector3> v = new List<Vector3>(), n = new List<Vector3>();
            public List<Vector4> u0 = new List<Vector4>(), u1 = new List<Vector4>(), u2 = new List<Vector4>();
            public List<int> idx = new List<int>();
            public Mesh ToMesh(string name)
            {
                var m = new Mesh { name = name, indexFormat = UnityEngine.Rendering.IndexFormat.UInt32 };
                m.SetVertices(v); if (n.Count == v.Count) m.SetNormals(n);
                m.SetUVs(0, u0); m.SetUVs(1, u1); m.SetUVs(2, u2);
                m.SetTriangles(idx, 0);
                m.bounds = new Bounds(Vector3.zero, Vector3.one * 2f * (TrafficRadius + 600f));
                v.Clear(); n.Clear(); u0.Clear(); u1.Clear(); u2.Clear(); idx.Clear();
                return m;
            }
        }

        static void AddLights(Acc a, Vector4 u0, Vector4 u1, Vector4 u2)
        {
            for (int head = 0; head <= 1; head++)   // 0 tail, 1 head
            {
                int b = a.v.Count;
                a.v.Add(new Vector3(-1, -1, head)); a.v.Add(new Vector3(1, -1, head));
                a.v.Add(new Vector3(1, 1, head));   a.v.Add(new Vector3(-1, 1, head));
                for (int k = 0; k < 4; k++) { a.u0.Add(u0); a.u1.Add(u1); a.u2.Add(u2); }
                a.idx.AddRange(new[] { b, b + 2, b + 1, b, b + 3, b + 2 });   // billboard; culling off anyway
            }
        }

        static void AddBody(Acc a, Mesh hull, Vector4 u0, Vector4 u1, Vector4 u2)
        {
            int b = a.v.Count;
            var hv = hull.vertices; var hn = hull.normals; var ht = hull.triangles;
            a.v.AddRange(hv); a.n.AddRange(hn);
            for (int k = 0; k < hv.Length; k++) { a.u0.Add(u0); a.u1.Add(u1); a.u2.Add(u2); }
            foreach (int t in ht) a.idx.Add(b + t);
        }
    }

    /// <summary>Sleek lofted hulls (car space: x forward, y up, z left), one per vehicle kind.</summary>
    public static class CarHull
    {
        const int Ring = 12, Stations = 13;

        public static Mesh Build(int kind)
        {
            var dims = CityTrafficBuilder.Dims[kind];
            float hl = dims.x, hw = dims.y;
            var v = new List<Vector3>(); var idx = new List<int>();
            for (int s = 0; s < Stations; s++)
            {
                float x01 = s / (Stations - 1f);               // 0 = tail, 1 = nose
                float x = Mathf.Lerp(-hl, hl, x01);
                Profile(kind, x01, hw, out float w, out float yb, out float yt, out float narrow, out float exp);
                for (int k = 0; k < Ring; k++)
                {
                    float a = k / (float)Ring * Mathf.PI * 2f;
                    float ca = Mathf.Cos(a), sa = Mathf.Sin(a);
                    float pz = Mathf.Sign(ca) * Mathf.Pow(Mathf.Abs(ca), 2f / exp);
                    float py = Mathf.Sign(sa) * Mathf.Pow(Mathf.Abs(sa), 2f / exp);
                    float mid = 0.5f * (yb + yt), hh = 0.5f * (yt - yb);
                    float y = mid + hh * py;
                    float z = w * pz * (py > 0 ? Mathf.Lerp(1f, narrow, py) : 1f);   // tumblehome
                    v.Add(new Vector3(x, y, z));
                }
            }
            for (int s = 0; s < Stations - 1; s++)
            for (int k = 0; k < Ring; k++)
            {
                int a0 = s * Ring + k, a1 = s * Ring + (k + 1) % Ring, b0 = a0 + Ring, b1 = a1 + Ring;
                idx.AddRange(new[] { a0, b0, a1, a1, b0, b1 });
            }
            // caps
            int ct = v.Count; v.Add(Centroid(v, 0)); int cn = v.Count; v.Add(Centroid(v, (Stations - 1) * Ring));
            for (int k = 0; k < Ring; k++)
            {
                int k1 = (k + 1) % Ring;
                // (wound to match the sides: the old order turned both caps inside out, so you could see
                //  straight through every car from the front or back)
                idx.AddRange(new[] { ct, k, k1 });
                idx.AddRange(new[] { cn, (Stations - 1) * Ring + k1, (Stations - 1) * Ring + k });
            }
            var m = new Mesh();
            m.SetVertices(v); m.SetTriangles(idx, 0);
            m.RecalculateNormals();
            // make sure the winding faces outward (flip if the first face points in)
            var n = m.normals;
            if (Vector3.Dot(n[Ring / 4], v[Ring / 4] - new Vector3(v[Ring / 4].x, 0, 0)) < 0)
            {
                for (int i = 0; i < idx.Count; i += 3) { int t = idx[i + 1]; idx[i + 1] = idx[i + 2]; idx[i + 2] = t; }
                m.SetTriangles(idx, 0); m.RecalculateNormals();
            }
            return m;
        }

        static Vector3 Centroid(List<Vector3> v, int start)
        {
            var c = Vector3.zero;
            for (int k = 0; k < Ring; k++) c += v[start + k];
            return c / Ring;
        }

        static float Bump(float x, float c, float w) { float d = (x - c) / w; return Mathf.Exp(-d * d * 4f); }

        // width, bottom, top, top-narrowing and superellipse exponent at x01 (0 tail .. 1 nose)
        static void Profile(int kind, float x01, float hw, out float w, out float yb, out float yt, out float narrow, out float exp)
        {
            // 0 at ends. Clamp: float Sin(PI) is -8.7e-8, and Pow(negative, frac) = NaN -> holes in the nose
            float endT = Mathf.Max(0f, Mathf.Sin(Mathf.Clamp01(x01) * Mathf.PI));
            switch (kind)
            {
                case CityTrafficBuilder.Saloon:
                    w = hw * Mathf.Lerp(0.55f, 1f, Mathf.Pow(endT, 0.35f));
                    yb = -0.32f + 0.12f * (1f - Mathf.Pow(endT, 0.4f));
                    yt = 0.12f + 0.12f * Mathf.Pow(endT, 0.5f) + 0.42f * Bump(x01, 0.42f, 0.55f);   // canopy
                    narrow = 0.62f; exp = 2.6f;
                    break;
                case CityTrafficBuilder.Van:
                    w = hw * Mathf.Lerp(0.7f, 1f, Mathf.Pow(endT, 0.25f));
                    yb = -0.9f + 0.15f * (1f - Mathf.Pow(endT, 0.3f));
                    yt = Mathf.Lerp(1.0f, 0.15f, Mathf.Pow(Mathf.Clamp01((x01 - 0.72f) / 0.28f), 1.4f));     // raked nose
                    narrow = 0.85f; exp = 3.5f;
                    break;
                case CityTrafficBuilder.Bus:
                    w = hw * Mathf.Lerp(0.8f, 1f, Mathf.Pow(endT, 0.2f));
                    yb = -1.15f + 0.2f * (1f - Mathf.Pow(endT, 0.25f));
                    yt = 1.2f - 0.25f * (1f - Mathf.Pow(endT, 0.25f));
                    narrow = 0.9f; exp = 4f;
                    break;
                default:
                    w = hw * Mathf.Lerp(0.85f, 1f, Mathf.Pow(endT, 0.15f));
                    yb = -1.35f + 0.15f * (1f - Mathf.Pow(endT, 0.2f));
                    yt = (x01 > 0.82f ? 1.0f : 1.45f) - 0.15f * (1f - Mathf.Pow(endT, 0.2f));      // cab lower than box
                    narrow = 0.95f; exp = 6f;
                    break;
            }
        }
    }
}
