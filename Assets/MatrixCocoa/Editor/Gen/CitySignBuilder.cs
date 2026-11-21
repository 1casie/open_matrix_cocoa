using System.Collections.Generic;
using System.IO;
using UnityEngine;
using static MatrixCocoa.Gen.CityRules;

namespace MatrixCocoa.Gen
{
    /// <summary>
    /// Neon. Signs are placed on the generated buildings near the viewer, clustered by a slow
    /// "entertainment district" noise and concentrated around eye level and down into the abyss.
    /// Lettering comes from a baked template atlas (Tools/make_sign_atlas.py -> SignAtlas.png/json):
    /// real Japanese / Chinese / Cyrillic / English words rendered as distance fields.
    ///
    /// Sign kinds: BLADE (vertical box jutting from the wall, text on both faces), BOARD (box or
    /// bare letters on the wall), SCREEN (jumbotron), ROOF (big channel letters on a steel truss).
    /// Styles (uv1.y): see STYLE_* in Shaders/Include/CitySigns.cginc.
    ///
    /// Two meshes: panels (MatrixCocoa/CitySign: faces + metal housings + trusses) and glows
    /// (MatrixCocoa/CitySignGlow: letter-shaped halos + coloured spill on the walls).
    /// Vertex layout: uv0 = (local x m, local y m, width m, height m); uv1 = (seed24, style, colour A, colour B);
    /// uv2 = atlas rect (u0, v0, u1, v1); uv3 = (part 0 face / 1 housing, letter count, -, -).
    /// </summary>
    public static class CitySignBuilder
    {
        public const float Radius = 1100f;   // beyond this, signs are a few pixels: the facade window dots carry on
        public const int Colours = 8;     // NEON[] in CityCommon.cginc / LB_PANEL[] in CitySigns.cginc
        public const string AtlasJson = "Assets/MatrixCocoa/Textures/SignAtlas.json";

        public const int StyleNeon = 0, StyleOutline = 1, StyleLightbox = 2, StyleChannel = 3,
                         StyleScreen = 4, StyleTruss = 5, StyleSpill = 6;

        [System.Serializable] public class Template { public string text, orient, font, script; public float u0, v0, u1, v1, aspect; public int units; }
        [System.Serializable] class Atlas { public int width, height; public float spread; public Template[] templates; }

        public struct Result { public Mesh panels, glows; public int count; }

        class Acc
        {
            public List<Vector3> v = new List<Vector3>(), n = new List<Vector3>();
            public List<Vector4> u0 = new List<Vector4>(), u1 = new List<Vector4>(), u2 = new List<Vector4>(), u3 = new List<Vector4>();
            public List<int> idx = new List<int>();
            public Mesh ToMesh(string name)
            {
                var m = new Mesh { name = name, indexFormat = UnityEngine.Rendering.IndexFormat.UInt32 };
                m.SetVertices(v); m.SetNormals(n);
                m.SetUVs(0, u0); m.SetUVs(1, u1); m.SetUVs(2, u2); m.SetUVs(3, u3);
                m.SetTriangles(idx, 0); m.RecalculateBounds();
                return m;
            }
        }

        static List<Template> vertical, horizontal;

        static void LoadAtlas()
        {
            var a = JsonUtility.FromJson<Atlas>(File.ReadAllText(AtlasJson));
            vertical = new List<Template>(); horizontal = new List<Template>();
            foreach (var t in a.templates) (t.orient == "v" ? vertical : horizontal).Add(t);
        }

        static float District(Vector2 p)
        {
            const float cell = 650f;
            float fx = p.x / cell, fy = p.y / cell;
            int ix = Mathf.FloorToInt(fx), iy = Mathf.FloorToInt(fy);
            float tx = fx - ix, ty = fy - iy;
            tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty);
            float H(int i, int j) => Rnd(Hash3i(i, j, 0x5167), 0u);
            float v = Mathf.Lerp(Mathf.Lerp(H(ix, iy), H(ix + 1, iy), tx), Mathf.Lerp(H(ix, iy + 1), H(ix + 1, iy + 1), tx), ty);
            return Mathf.SmoothStep(0.2f, 0.85f, v);
        }

        public static Result Build()
        {
            LoadAtlas();
            Vector2 anchor = Anchor;
            Vector3 off = CityMeshBuilder.CityOffset;
            int r = Mathf.CeilToInt(Radius / Block) + 1;
            int ci = Mathf.FloorToInt(anchor.x / Block), cj = Mathf.FloorToInt(anchor.y / Block);
            var lots = new List<Lot>();
            var prisms = new List<Prism>();
            var pa = new Acc(); var ga = new Acc();
            int count = 0;
            for (int j = cj - r; j <= cj + r; j++)
            for (int i = ci - r; i <= ci + r; i++)
            {
                lots.Clear();
                CellLots(i, j, lots);
                foreach (var L in lots)
                {
                    if ((L.q.Centre - anchor).magnitude > Radius) continue;
                    float dist = District(L.q.Centre);
                    prisms.Clear();
                    LotBuilding(L, prisms);
                    foreach (var p in prisms)
                    {
                        if (p.stage > 2) continue;
                        for (int e = 0; e < 4; e++) count += WallSigns(pa, ga, p, e, dist, off);
                        bool topped = false;   // rooftop letters only where no tower stands on the roof
                        foreach (var q in prisms) if (Mathf.Abs(q.y0 - p.y1) < 0.01f) { topped = true; break; }
                        if (!topped) count += RoofSign(pa, ga, p, dist, off);
                    }
                }
            }
            return new Result { panels = pa.ToMesh("signs"), glows = ga.ToMesh("sign_glows"), count = count };
        }

        // ---------------------------------------------------------------- choosing a look
        static int StyleFor(Template t, uint s)
        {
            float r = Rnd(s, 40u);
            switch (t.font)
            {
                case "sans_light":
                case "oswald_light": return r < 0.85f ? StyleNeon : StyleLightbox;
                case "serif":        return r < 0.8f ? StyleLightbox : StyleNeon;
                case "sans_bold":    return r < 0.6f ? StyleLightbox : StyleOutline;
                default:             return r < 0.5f ? StyleOutline : r < 0.8f ? StyleLightbox : StyleNeon;   // russo / oswald
            }
        }

        static Vector4 Rect(Template t) => new Vector4(t.u0, t.v0, t.u1, t.v1);

        // ---------------------------------------------------------------- wall signs
        // occupied rectangles on the current wall, in (u along the wall, y) metres
        static readonly List<Rect> taken = new List<Rect>();
        static bool Free(Rect r)
        {
            foreach (var t in taken) if (t.Overlaps(r)) return false;
            return true;
        }

        static int WallSigns(Acc pa, Acc ga, Prism p, int e, float district, Vector3 off)
        {
            Vector2 A = p.f[e], B = p.f[(e + 1) & 3];
            Vector2 D = B - A; float len = D.magnitude; if (len < 14f) return 0;
            D /= len;
            var T = new Vector3(D.x, 0, D.y);
            var N = new Vector3(D.y, 0, -D.x);
            float yLo = Mathf.Max(p.y0 + 1f, -450f), yHi = Mathf.Min(p.y1 - 2.5f, 380f);
            if (yHi - yLo < 8f) return 0;
            uint ws = HashU(p.seed, 0xA11u + (uint)e);
            float expected = (0.3f + 5f * district) * len * (yHi - yLo) / 4000f;
            int n = Mathf.Min(60, Mathf.FloorToInt(expected + Rnd(ws, 0u)));
            int made = 0;
            taken.Clear();
            for (int k = 0; k < n; k++)
            {
                uint s = HashU(ws, (uint)k + 1u);
                float kindR = Rnd(s, 0u);
                int ca = (int)(Pcg(s) % Colours), cb = (int)(Pcg(s + 9u) % Colours);
                uint seed = Pcg(s) & 0xFFFFFFu;
                float yWant = Rnd(s, 5u) < 0.6f ? CityMeshBuilder.AnchorAltitude + (Rnd(s, 6u) - 0.5f) * 140f : Mathf.Lerp(yLo, yHi, Rnd(s, 2u));   // most near eye level

                if (kindR < 0.5f)
                {
                    // BLADE: a box jutting out of the wall, vertical text on both faces
                    var t = vertical[(int)(Pcg(s + 1u) % (uint)vertical.Count)];
                    float w = Mathf.Lerp(1.5f, 2.8f, Rnd(s, 3u));
                    float h = w / t.aspect;
                    if (h > yHi - yLo) continue;
                    float u = Mathf.Lerp(2.5f, len - 2.5f, Rnd(s, 1u));
                    float yc = Mathf.Clamp(yWant, yLo + h * 0.5f, yHi - h * 0.5f);
                    // a blade claims a strip of wall (it sticks out, so keep its neighbours clear)
                    var rect = new Rect(u - 2.2f, yc - h * 0.5f - 1.2f, 4.4f, h + 2.4f);
                    if (!Free(rect)) continue;
                    taken.Add(rect);
                    float th = Mathf.Lerp(0.35f, 0.6f, Rnd(s, 4u));
                    int style = StyleFor(t, s);
                    var info = new Vector4(seed, style, ca, cb);
                    Vector3 o = W(A + D * u, yc, off) + N * (0.7f + w * 0.5f);
                    // front face normal T reads with X = -N; back face normal -T reads with X = N
                    Box(pa, o, -N, Vector3.up, T, w, h, th, info, Rect(t), t.units, true);
                    Glow(ga, o, -N, Vector3.up, T, w, h, info, Rect(t), t.units);      // one halo, seen from both sides
                    var spill = new Vector4(seed, StyleSpill, ca, cb);
                    Glow(ga, W(A + D * u, yc, off) + N * 0.06f, T, Vector3.up, N, 2f * w + 4f, h + 3f, spill, Rect(t), 0, 0f, style);
                }
                else
                {
                    bool screen = kindR > 0.95f;
                    float h, w; Template t;
                    if (screen)
                    {
                        // SCREEN: a rare jumbotron
                        t = horizontal[(int)(Pcg(s + 2u) % (uint)horizontal.Count)];
                        h = Mathf.Lerp(7f, 14f, Rnd(s, 3u));
                        w = h * Mathf.Lerp(1.4f, 1.9f, Rnd(s, 4u));
                    }
                    else
                    {
                        // BOARD: horizontal sign flat on the wall (a lightbox, or bare tube letters)
                        t = horizontal[(int)(Pcg(s + 2u) % (uint)horizontal.Count)];
                        h = Mathf.Lerp(2.2f, 5.5f, Rnd(s, 3u)) * (t.orient == "h2" ? 1.35f : 1f);
                        w = h * t.aspect;
                    }
                    if (w > len - 4f) { if (screen) continue; h *= (len - 4f) / w; w = len - 4f; }
                    if (h < 1.2f || h > yHi - yLo) continue;
                    float u = Mathf.Lerp(w * 0.5f + 2f, len - w * 0.5f - 2f, Rnd(s, 1u));
                    float yc = Mathf.Clamp(yWant, yLo + h * 0.5f, yHi - h * 0.5f);
                    var rect = new Rect(u - w * 0.5f - 1f, yc - h * 0.5f - 1f, w + 2f, h + 2f);
                    if (!Free(rect)) continue;
                    taken.Add(rect);
                    var tpl = t;
                    if (screen)
                    {
                        var info = new Vector4(seed, StyleScreen, ca, cb);
                        Vector3 o = W(A + D * u, yc, off) + N * 0.45f;
                        Box(pa, o, T, Vector3.up, N, w, h, 0.6f, info, Rect(tpl), 0, false);
                        Glow(ga, o + N * 0.32f, T, Vector3.up, N, w, h, info, Rect(tpl), 0);
                    }
                    else
                    {
                        int style = StyleFor(tpl, s);
                        bool bare = style != StyleLightbox && Rnd(s, 7u) < 0.5f;
                        float th = bare ? 0f : Mathf.Lerp(0.25f, 0.45f, Rnd(s, 4u));
                        var info = new Vector4(seed, style, ca, cb);
                        Vector3 o = W(A + D * u, yc, off) + N * (th * 0.5f + 0.15f);
                        Box(pa, o, T, Vector3.up, N, w, h, th, info, Rect(tpl), 0, false, bare);
                        Glow(ga, o + N * (th * 0.5f - 0.1f), T, Vector3.up, N, w, h, info, Rect(tpl), 0);
                    }
                }
                made++;
            }
            return made;
        }

        static int RoofSign(Acc pa, Acc ga, Prism p, float district, Vector3 off)
        {
            if (p.y1 > 650f || p.y1 < -50f) return 0;
            if (p.seed == Site.prismSeed) return 0;          // that roof is the station's
            uint s = HashU(p.seed, 0x2F0Fu);
            if (Rnd(s, 0u) > 0.1f + 0.6f * district) return 0;
            int e = (int)(Pcg(s) & 3u);
            Vector2 A = p.f[e], B = p.f[(e + 1) & 3];
            Vector2 D = B - A; float len = D.magnitude; if (len < 25f) return 0;
            D /= len;
            var T = new Vector3(D.x, 0, D.y);
            var N = new Vector3(D.y, 0, -D.x);
            var t = horizontal[(int)(Pcg(s + 5u) % (uint)horizontal.Count)];
            float h = Mathf.Lerp(5f, 10f, Rnd(s, 1u));
            float w = h * t.aspect;
            if (w > len * 0.85f) { h *= len * 0.85f / w; w = len * 0.85f; }
            int ca = (int)(Pcg(s) % Colours), cb = (int)(Pcg(s + 3u) % Colours);
            uint seed = Pcg(s) & 0xFFFFFFu;
            int style = Rnd(s, 2u) < 0.6f ? StyleChannel : StyleOutline;
            Vector3 o = W(A + D * (len * 0.5f), p.y1 + h * 0.5f + 1.2f, off) - N * 2f;
            var info = new Vector4(seed, style, ca, cb);
            Face(pa, o, T, Vector3.up, N, w, h, info, Rect(t), 0, 0f);
            // the steel truss behind the letters, down to the roof
            var truss = new Vector4(seed, StyleTruss, ca, cb);
            Face(pa, o - N * 0.8f - Vector3.up * 0.6f, T, Vector3.up, N, w, h + 1.2f, truss, Rect(t), 0, 0f);
            Glow(ga, o + N * 0.05f, T, Vector3.up, N, w, h, info, Rect(t), 0);
            return 1;
        }

        /// <summary>
        /// One hand-placed sign (e.g. over the station hangar) using an atlas template by its text.
        /// Positions are in the space of whatever object the meshes will hang under.
        /// </summary>
        public static bool MakeSign(string text, Vector3 centre, Vector3 X, Vector3 nrm, float height, int style, int ca, int cb,
                                    out Mesh panel, out Mesh glow, out float width)
        {
            LoadAtlas();
            Template t = null;
            foreach (var c in horizontal) if (c.text == text) { t = c; break; }
            if (t == null) foreach (var c in vertical) if (c.text == text) { t = c; break; }
            panel = glow = null; width = 0;
            if (t == null) { Debug.LogWarning($"[MatrixCocoa] no sign template '{text}' - add it to Tools/make_sign_atlas.py"); return false; }
            width = height * t.aspect;
            var pa = new Acc(); var ga = new Acc();
            var info = new Vector4(0x5A7105u, style, ca, cb);
            Face(pa, centre, X, Vector3.up, nrm, width, height, info, Rect(t), t.units, 0f);
            Glow(ga, centre - nrm * 0.03f, X, Vector3.up, nrm, width, height, info, Rect(t), t.units);
            panel = pa.ToMesh("sign_" + text); glow = ga.ToMesh("glow_" + text);
            return true;
        }

        static Vector3 W(Vector2 xz, float y, Vector3 off) => new Vector3(xz.x - off.x, y - off.y, xz.y - off.z);

        // ---------------------------------------------------------------- geometry
        // A face quad centred on o: X runs left->right as seen from the front, Y up, nrm towards the viewer.
        static void Face(Acc a, Vector3 o, Vector3 X, Vector3 Y, Vector3 nrm, float w, float h, Vector4 info, Vector4 rect, int units, float part, float pad = 0f, float look = 0f)
        {
            int b = a.v.Count;
            float x0 = -pad, x1 = w + pad, y0 = -pad, y1 = h + pad;
            Vector3 c0 = o - X * (w * 0.5f) - Y * (h * 0.5f);
            a.v.Add(c0 + X * x0 + Y * y0); a.u0.Add(new Vector4(x0, y0, w, h));
            a.v.Add(c0 + X * x1 + Y * y0); a.u0.Add(new Vector4(x1, y0, w, h));
            a.v.Add(c0 + X * x1 + Y * y1); a.u0.Add(new Vector4(x1, y1, w, h));
            a.v.Add(c0 + X * x0 + Y * y1); a.u0.Add(new Vector4(x0, y1, w, h));
            for (int k = 0; k < 4; k++) { a.n.Add(nrm); a.u1.Add(info); a.u2.Add(rect); a.u3.Add(new Vector4(part, units, look, 0)); }
            a.idx.AddRange(new[] { b, b + 2, b + 1, b, b + 3, b + 2 });
        }

        // A sign box: front face (+ back face for blades) and the metal housing around it.
        static void Box(Acc a, Vector3 o, Vector3 X, Vector3 Y, Vector3 Z, float w, float h, float th, Vector4 info, Vector4 rect, int units, bool twoFaced, bool bare = false)
        {
            Face(a, o + Z * (th * 0.5f), X, Y, Z, w, h, info, rect, units, bare ? -1f : 0f);   // part -1 = bare letters (cut out)
            if (twoFaced) Face(a, o - Z * (th * 0.5f), -X, Y, -Z, w, h, info, rect, units, 0f);
            if (bare || th <= 0f) return;
            // housing: top, bottom, two ends (local coords: along the side, across the depth)
            Face(a, o + Y * (h * 0.5f), X, Z, Y, w, th, info, rect, units, 1f);
            Face(a, o - Y * (h * 0.5f), X, -Z, -Y, w, th, info, rect, units, 1f);
            Face(a, o + X * (w * 0.5f), -Z, Y, X, th, h, info, rect, units, 1f);
            Face(a, o - X * (w * 0.5f), Z, Y, -X, th, h, info, rect, units, 1f);
        }

        static void Glow(Acc a, Vector3 o, Vector3 X, Vector3 Y, Vector3 nrm, float w, float h, Vector4 info, Vector4 rect, int units, float padOverride = -1f, float look = 0f)
        {
            float pad = padOverride >= 0f ? padOverride : 0.6f * Mathf.Min(w, h) + 2.5f;
            Face(a, o, X, Y, nrm, w, h, info, rect, units, 0f, pad, look);
        }
    }
}
