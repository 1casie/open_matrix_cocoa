using UnityEditor;
using UnityEngine;

namespace MatrixCocoa.EditorTools
{
    /// <summary>
    /// Rough GPU cost of the city at VR resolution: renders a view N times into an eye-sized
    /// target and forces a GPU sync. Editor numbers only - VRChat adds its own overhead and
    /// renders TWO eyes (single-pass instanced, so roughly double the pixel work).
    /// </summary>
    public static class CityBench
    {
        public static string Run(int w = 2016, int h = 2240, int frames = 6, string preset = "Night")
        {
            if (preset != null) CityPresets.ApplyToScene(CityPresets.ByName(preset));
            var go = new GameObject("~BenchCam") { hideFlags = HideFlags.HideAndDontSave };
            var cam = go.AddComponent<Camera>();
            cam.clearFlags = CameraClearFlags.Skybox;
            cam.fieldOfView = 105;
            cam.nearClipPlane = 0.05f; cam.farClipPlane = 9000f;
            var rt = new RenderTexture(w, h, 24, RenderTextureFormat.ARGB32);
            var px = new Texture2D(1, 1, TextureFormat.RGBA32, false);
            cam.targetTexture = rt;
            var sb = new System.Text.StringBuilder();
            try
            {
                foreach (var s in CityCapture.Shots)
                {
                    var spawn = GameObject.Find(SceneBuilder.RootName + "/Spawn");
                    if (spawn != null) go.transform.SetPositionAndRotation(spawn.transform.TransformPoint(s.pos), spawn.transform.rotation * Quaternion.Euler(s.euler));
                    else go.transform.SetPositionAndRotation(s.pos, Quaternion.Euler(s.euler));
                    cam.Render(); Sync(rt, px);                  // warm-up
                    var sw = System.Diagnostics.Stopwatch.StartNew();
                    for (int i = 0; i < frames; i++) { cam.Render(); Sync(rt, px); }
                    sb.AppendLine($"{s.name,-8} {sw.Elapsed.TotalMilliseconds / frames,6:F1} ms/eye");
                }
            }
            finally
            {
                cam.targetTexture = null;
                Object.DestroyImmediate(go); Object.DestroyImmediate(rt); Object.DestroyImmediate(px);
            }
            return $"{w}x{h} per eye, {preset}\n" + sb;
        }

        static void Sync(RenderTexture rt, Texture2D px)
        {
            RenderTexture.active = rt;
            px.ReadPixels(new Rect(0, 0, 1, 1), 0, 0);
            px.Apply();
            RenderTexture.active = null;
        }
    }
}
