using System.IO;
using UnityEditor;
using UnityEngine;

namespace MatrixCocoa.EditorTools
{
    /// <summary>
    /// Packs the Poly Haven facade textures (Tools/fetch_polyhaven.py) into two flipbook PNGs
    /// that Unity imports as Texture2DArrays (albedo = sRGB, normal = linear).
    /// Slice i = TEXTURES[i] in the fetch script = FACADE_TEX_SIZE[i] in CityCommon.cginc.
    /// </summary>
    public static class CityTextures
    {
        public static readonly string[] Ids = { "concrete", "concrete_wall_006", "concrete_slab_wall_02", "concrete_tile_facade" };
        const string Src = "Assets/ThirdParty/PolyHaven/Textures";
        const string OutDir = "Assets/MatrixCocoa/Textures";
        public const string AlbedoPath = OutDir + "/FacadeAlbedoArray.png";
        public const string NormalPath = OutDir + "/FacadeNormalArray.png";
        const int Size = 1024;

        [MenuItem("Matrix Cocoa/Rebuild Texture Arrays")]
        public static void Build()
        {
            Directory.CreateDirectory(OutDir);
            Pack("diff", AlbedoPath, true);
            Pack("nor_gl", NormalPath, false);
            BuildNoise();
            Debug.Log("[MatrixCocoa] facade texture arrays rebuilt");
        }

        public const string NoisePath = OutDir + "/CityNoise.asset";

        /// <summary>
        /// A 256^2 tiling noise texture: much cheaper per pixel than hashing value noise in the
        /// shader. R = value noise (8 cells), G = 4-octave fbm, B = value noise (16 cells),
        /// A = value noise (32 cells). All channels tile seamlessly.
        /// </summary>
        public static Texture2D BuildNoise()
        {
            const int N = 256;
            var px = new Color[N * N];
            for (int y = 0; y < N; y++)
            for (int x = 0; x < N; x++)
            {
                float u = x / (float)N, v = y / (float)N;
                float fbm = 0, a = 0.5f, norm = 0;
                for (int o = 0; o < 4; o++) { fbm += a * Periodic(u, v, 8 << o, 11u + (uint)o); norm += a; a *= 0.5f; }
                px[y * N + x] = new Color(Periodic(u, v, 8, 1u), fbm / norm, Periodic(u, v, 16, 2u), Periodic(u, v, 32, 3u));
            }
            var t = new Texture2D(N, N, TextureFormat.RGBA32, true, true) { name = "CityNoise", wrapMode = TextureWrapMode.Repeat, filterMode = FilterMode.Trilinear };
            t.SetPixels(px); t.Apply(true, false);
            AssetDatabase.DeleteAsset(NoisePath);
            AssetDatabase.CreateAsset(t, NoisePath);
            return t;
        }

        // smooth value noise with `cells` cells per tile, wrapping at the tile edge
        static float Periodic(float u, float v, int cells, uint salt)
        {
            float fx = u * cells, fy = v * cells;
            int ix = Mathf.FloorToInt(fx), iy = Mathf.FloorToInt(fy);
            float tx = fx - ix, ty = fy - iy;
            tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty);
            float H(int i, int j) => Gen.CityRules.Rnd(Gen.CityRules.Hash3i(((i % cells) + cells) % cells, ((j % cells) + cells) % cells, (int)salt), 0u);
            return Mathf.Lerp(Mathf.Lerp(H(ix, iy), H(ix + 1, iy), tx), Mathf.Lerp(H(ix, iy + 1), H(ix + 1, iy + 1), tx), ty);
        }

        static void Pack(string suffix, string outPath, bool srgb)
        {
            int n = Ids.Length;
            var sheet = new Texture2D(Size, Size * n, TextureFormat.RGB24, false);
            for (int i = 0; i < n; i++)
            {
                string p = $"{Src}/{Ids[i]}/{Ids[i]}_{suffix}_1k.jpg";
                var t = new Texture2D(2, 2);
                t.LoadImage(File.ReadAllBytes(p));
                if (t.width != Size || t.height != Size) Debug.LogWarning($"[MatrixCocoa] {p} is {t.width}x{t.height}, expected {Size}");
                // flipbook slices run top to bottom; texture rows run bottom to top
                sheet.SetPixels(0, (n - 1 - i) * Size, Size, Size, t.GetPixels(0, 0, Size, Size));
                Object.DestroyImmediate(t);
            }
            File.WriteAllBytes(outPath, sheet.EncodeToPNG());
            Object.DestroyImmediate(sheet);
            AssetDatabase.ImportAsset(outPath, ImportAssetOptions.ForceSynchronousImport);

            var imp = (TextureImporter)AssetImporter.GetAtPath(outPath);
            imp.textureType = TextureImporterType.Default;
            imp.textureShape = TextureImporterShape.Texture2DArray;
            var ts = new TextureImporterSettings();
            imp.ReadTextureSettings(ts);
            ts.flipbookRows = n;
            ts.flipbookColumns = 1;
            imp.SetTextureSettings(ts);
            imp.sRGBTexture = srgb;
            imp.mipmapEnabled = true;
            imp.wrapMode = TextureWrapMode.Repeat;
            imp.filterMode = FilterMode.Trilinear;
            imp.anisoLevel = 4;
            imp.maxTextureSize = 8192;
            imp.textureCompression = TextureImporterCompression.CompressedHQ;
            imp.SaveAndReimport();
        }
    }
}
