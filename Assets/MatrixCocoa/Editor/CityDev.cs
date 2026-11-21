using UnityEditor;
using UnityEngine;

namespace MatrixCocoa.EditorTools
{
    /// <summary>
    /// Iteration helpers (handy from the MCP bridge):
    ///   CityDev.Iterate("Day", "highway,down")  -> reimport shaders, report errors, capture shots
    /// </summary>
    public static class CityDev
    {
        public static readonly string[] Shaders =
        {
            "Assets/MatrixCocoa/Shaders/CityFacade.shader",
            "Assets/MatrixCocoa/Shaders/CitySky.shader",
            "Assets/MatrixCocoa/Shaders/CityCar.shader",
            "Assets/MatrixCocoa/Shaders/CityCarLights.shader",
            "Assets/MatrixCocoa/Shaders/CitySign.shader",
            "Assets/MatrixCocoa/Shaders/CitySignGlow.shader",
        };

        public static string ShaderReport(bool reimport = true)
        {
            var sb = new System.Text.StringBuilder();
            foreach (var path in Shaders)
            {
                if (reimport) AssetDatabase.ImportAsset(path, ImportAssetOptions.ForceUpdate | ImportAssetOptions.ForceSynchronousImport);
                var sh = AssetDatabase.LoadAssetAtPath<Shader>(path);
                if (sh == null) { sb.AppendLine(path + ": missing"); continue; }
                ShaderUtil.CompilePass(new Material(sh), 0, true);
                foreach (var m in ShaderUtil.GetShaderMessages(sh))
                    if (m.severity == UnityEditor.Rendering.ShaderCompilerMessageSeverity.Error)
                        sb.AppendLine($"ERROR {m.file}:{m.line} {m.message}");
            }
            return sb.Length == 0 ? "shaders OK" : sb.ToString();
        }

        public static string Iterate(string preset, string shots, int w = 960, int h = 540)
        {
            AssetDatabase.Refresh();
            string rep = ShaderReport();
            if (rep != "shaders OK") return rep;
            return rep + "\n" + CityCapture.Capture(preset, shots, w, h);
        }
    }
}
