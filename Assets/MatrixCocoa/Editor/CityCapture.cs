using System.IO;
using UnityEditor;
using UnityEngine;

namespace MatrixCocoa.EditorTools
{
    /// <summary>
    /// Review shots of the city rendered to Captures/*.png
    /// (outside Assets, so they never get imported). Menu: Matrix Cocoa > Capture Review Shots.
    /// From the MCP bridge: MatrixCocoa.EditorTools.CityCapture.Capture("Night", "down,up").
    /// </summary>
    public static class CityCapture
    {
        public struct Shot
        {
            public string name; public Vector3 pos; public Vector3 euler; public float fov;
            public Shot(string n, Vector3 p, Vector3 e, float f) { name = n; pos = p; euler = e; fov = f; }
        }

        // Positions and rotations are relative to the city spawn, facing the street.
        // euler: x = pitch (positive looks DOWN), y = yaw (0 = out over the street)
        public static readonly Shot[] Shots =
        {
            new Shot("highway", new Vector3(0f, 1.1f, 0f), new Vector3(2, 0, 0), 75),
            new Shot("down",    new Vector3(0f, 1.1f, 0f), new Vector3(55, 0, 0), 80),
            new Shot("abyss",   new Vector3(0f, 1.1f, 0f), new Vector3(86, 0, 0), 90),
            new Shot("up",      new Vector3(0f, 1.1f, 0f), new Vector3(-45, 30, 0), 80),
            new Shot("across",  new Vector3(0f, 1.1f, 0f), new Vector3(6, 65, 0), 80),
            new Shot("cars",    new Vector3(0f, 1.1f, 0f), new Vector3(35, 20, 0), 70),
            new Shot("signs_a", new Vector3(0f, 1.1f, 0f), new Vector3(6, 10, 0), 32),
            new Shot("signs_b", new Vector3(0f, 1.1f, 0f), new Vector3(12, -40, 0), 28),
            new Shot("signs_c", new Vector3(0f, 1.1f, 0f), new Vector3(0, 45, 0), 22),
            new Shot("wide",    new Vector3(0f, 1.1f, 0f), new Vector3(14, 30, 0), 100),
        };

        public static string OutDir => Path.GetFullPath(Path.Combine(Application.dataPath, "..", "Captures"));

        [MenuItem("Matrix Cocoa/Capture Review Shots (all presets)")]
        static void MenuAll() { foreach (var p in CityPresets.All) Capture(p.name, null); }

        [MenuItem("Matrix Cocoa/Capture Review Shots (current preset)")]
        static void MenuCurrent() => Capture(EditorPrefs.GetString("MatrixCocoa.Preset", "Day"), null);

        /// <param name="preset">Day / Sunset / Night (applied first), or null to keep the current one</param>
        /// <param name="names">comma-separated shot names, or null for all</param>
        public static string Capture(string preset, string names, int width = 1280, int height = 720)
        {
            if (preset != null) CityPresets.ApplyToScene(CityPresets.ByName(preset));
            string tag = preset ?? EditorPrefs.GetString("MatrixCocoa.Preset", "Day");
            Directory.CreateDirectory(OutDir);

            var go = new GameObject("~CaptureCam") { hideFlags = HideFlags.HideAndDontSave };
            var cam = go.AddComponent<Camera>();
            cam.clearFlags = CameraClearFlags.Skybox;
            cam.nearClipPlane = 0.05f; cam.farClipPlane = 9000f;
            cam.allowHDR = false;
            var rt = new RenderTexture(width, height, 24, RenderTextureFormat.ARGB32, RenderTextureReadWrite.sRGB) { antiAliasing = 1 };
            var tex = new Texture2D(width, height, TextureFormat.RGB24, false);
            var log = new System.Text.StringBuilder();
            try
            {
                foreach (var s in Shots)
                {
                    if (names != null && !("," + names + ",").Contains("," + s.name + ",")) continue;
                    var spawn = GameObject.Find(SceneBuilder.RootName + "/Spawn");
                    if (spawn != null) go.transform.SetPositionAndRotation(spawn.transform.TransformPoint(s.pos), spawn.transform.rotation * Quaternion.Euler(s.euler));
                    else go.transform.SetPositionAndRotation(s.pos, Quaternion.Euler(s.euler));
                    cam.fieldOfView = s.fov;
                    cam.targetTexture = rt;
                    var t0 = System.Diagnostics.Stopwatch.StartNew();
                    cam.Render();
                    RenderTexture.active = rt;
                    tex.ReadPixels(new Rect(0, 0, width, height), 0, 0);
                    tex.Apply();
                    RenderTexture.active = null;
                    string f = Path.Combine(OutDir, $"{tag.ToLower()}_{s.name}.png");
                    File.WriteAllBytes(f, tex.EncodeToPNG());
                    log.AppendLine($"{f} ({t0.ElapsedMilliseconds} ms)");
                }
            }
            finally
            {
                cam.targetTexture = null;
                Object.DestroyImmediate(go);
                Object.DestroyImmediate(rt);
                Object.DestroyImmediate(tex);
            }
            return log.ToString();
        }
    }
}
