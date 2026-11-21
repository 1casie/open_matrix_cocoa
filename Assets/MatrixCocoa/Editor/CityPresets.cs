using System;
using UnityEditor;
using UnityEngine;

namespace MatrixCocoa.EditorTools
{
    /// <summary>
    /// The three times of day. Each preset is just a bag of material values for
    /// every city material (the shared block in each shader) plus scene ambient / avatar light.
    /// Tweak the numbers here, then Matrix Cocoa > Lighting > (preset) to apply.
    /// Colours are linear HDR radiance; the shader tone-maps with _Exposure.
    /// </summary>
    public class CityPreset
    {
        public string name;
        public float sunElevation, sunAzimuth;   // degrees; azimuth 0 = +z, 90 = +x
        public float sunVisibility;              // 0 = no direct sun (night)
        public Color sun, zenith, horizon, clouds;
        public float cloudCover;
        public Color fog; public float fogDensity, fogFalloff;
        public Color abyss, ambientSky, ambientGround;
        public float windowLit, windowIntensity, underLit, carIntensity;
        public float snowAmount, snowCover, exposure;
        public float neonIntensity = 4f;

        public Vector3 SunDirection
        {
            get
            {
                float e = sunElevation * Mathf.Deg2Rad, a = sunAzimuth * Mathf.Deg2Rad;
                return new Vector3(Mathf.Cos(e) * Mathf.Sin(a), Mathf.Sin(e), Mathf.Cos(e) * Mathf.Cos(a));
            }
        }

        internal Vector4 ShaderSun
        {
            get
            {
                Vector3 direction = SunDirection;
                return new Vector4(direction.x, direction.y, direction.z, sunVisibility);
            }
        }

        internal Color AvatarSky => Capped(ambientSky * (exposure * 0.7f), 0.18f);
        internal Color AvatarEquator => Capped(Color.Lerp(fog, ambientSky, 0.5f) * (exposure * 0.7f), 0.16f);
        internal Color AvatarGround => Capped((ambientGround * 2f + abyss * 0.5f) * (exposure * 0.7f), 0.12f);

        static Color Capped(Color color, float ceiling)
        {
            float peak = Mathf.Max(color.r, Mathf.Max(color.g, color.b));
            return peak > ceiling ? color * (ceiling / peak) : color;
        }
        internal Color SnowColor => CityPresets.Tonemap(
            ambientSky * 1.6f + sun * (sunVisibility * 0.35f) + ambientGround * 1.5f + new Color(0.02f, 0.02f, 0.02f),
            exposure);

        internal void GetAvatarSun(out Quaternion rotation, out float intensity, out Color color)
        {
            rotation = Quaternion.LookRotation(-SunDirection);
            Color c = sun * sunVisibility * 0.4f;
            intensity = Mathf.Max(c.r, Mathf.Max(c.g, c.b));
            color = intensity > 0f ? c / intensity : Color.black;
        }
    }

    public static class CityPresets
    {
        public const string MatDir = "Assets/MatrixCocoa/Materials";
        public const string SkyMat = MatDir + "/CitySky.mat";
        public const string FacadeMat = MatDir + "/CityFacade.mat";
        public const string CarMat = MatDir + "/CityCar.mat";
        public const string CarLightsMat = MatDir + "/CityCarLights.mat";
        public const string SignMat = MatDir + "/CitySign.mat";
        public const string SignGlowMat = MatDir + "/CitySignGlow.mat";
        /// <summary>Every material that shares the city block of properties.</summary>
        public static readonly string[] CityMaterials = { SkyMat, FacadeMat, CarMat, CarLightsMat, SignMat, SignGlowMat };

        public static readonly CityPreset Day = new CityPreset
        {
            name = "Day",
            sunElevation = 17, sunAzimuth = 155, sunVisibility = 0.55f,
            sun = new Color(2.4f, 2.25f, 2.0f),
            zenith = new Color(0.36f, 0.43f, 0.55f), horizon = new Color(0.66f, 0.7f, 0.76f),
            clouds = new Color(0.58f, 0.61f, 0.66f), cloudCover = 0.75f,
            fog = new Color(0.56f, 0.6f, 0.66f), fogDensity = 0.00055f, fogFalloff = 700f,
            abyss = new Color(0.26f, 0.27f, 0.29f),
            ambientSky = new Color(1.0f, 1.08f, 1.2f), ambientGround = new Color(0.12f, 0.11f, 0.1f),
            windowLit = 0.1f, windowIntensity = 0.9f, underLit = 0.8f, carIntensity = 2.5f,
            snowAmount = 0.25f, snowCover = 0.85f, exposure = 1.0f, neonIntensity = 2.2f,
        };

        public static readonly CityPreset Sunset = new CityPreset
        {
            name = "Sunset",
            sunElevation = 4, sunAzimuth = 262, sunVisibility = 1,
            sun = new Color(2.5f, 1.45f, 0.75f),
            zenith = new Color(0.17f, 0.21f, 0.34f), horizon = new Color(0.8f, 0.52f, 0.4f),
            clouds = new Color(0.4f, 0.33f, 0.36f), cloudCover = 0.55f,
            fog = new Color(0.42f, 0.4f, 0.45f), fogDensity = 0.0005f, fogFalloff = 650f,
            abyss = new Color(0.12f, 0.09f, 0.09f),
            ambientSky = new Color(0.36f, 0.4f, 0.52f), ambientGround = new Color(0.07f, 0.05f, 0.04f),
            windowLit = 0.3f, windowIntensity = 1.5f, underLit = 0.9f, carIntensity = 5f,
            snowAmount = 0.25f, snowCover = 0.85f, exposure = 1.1f, neonIntensity = 3.5f,
        };

        public static readonly CityPreset Night = new CityPreset
        {
            name = "Night",
            sunElevation = 35, sunAzimuth = 40, sunVisibility = 0,
            sun = Color.black,
            zenith = new Color(0.016f, 0.022f, 0.05f), horizon = new Color(0.07f, 0.06f, 0.1f),
            clouds = new Color(0.16f, 0.085f, 0.11f), cloudCover = 0.85f,
            fog = new Color(0.055f, 0.055f, 0.09f), fogDensity = 0.0006f, fogFalloff = 650f,
            abyss = new Color(0.12f, 0.05f, 0.02f),
            ambientSky = new Color(0.025f, 0.03f, 0.05f), ambientGround = new Color(0.03f, 0.018f, 0.01f),
            windowLit = 0.3f, windowIntensity = 1.6f, underLit = 1.0f, carIntensity = 6f,
            snowAmount = 0.4f, snowCover = 0.85f, exposure = 1.5f, neonIntensity = 4.5f,
        };

        /// <summary>The one true mood: a very blue, very foggy afternoon, snowing. The sun is a pale
        /// smudge behind the overcast; the city dissolves into blue haze a few blocks out.</summary>
        public static readonly CityPreset Snowfall = new CityPreset
        {
            name = "Snowfall",
            sunElevation = 16, sunAzimuth = 200, sunVisibility = 0.18f,
            sun = new Color(1.6f, 1.75f, 2.1f),
            zenith = new Color(0.22f, 0.32f, 0.55f), horizon = new Color(0.46f, 0.58f, 0.82f),
            clouds = new Color(0.42f, 0.52f, 0.74f), cloudCover = 0.97f,
            fog = new Color(0.38f, 0.5f, 0.76f), fogDensity = 0.0042f, fogFalloff = 900f,
            abyss = new Color(0.1f, 0.15f, 0.3f),
            ambientSky = new Color(0.62f, 0.78f, 1.15f), ambientGround = new Color(0.07f, 0.09f, 0.14f),
            windowLit = 0.22f, windowIntensity = 1.2f, underLit = 0.7f, carIntensity = 3.5f,
            snowAmount = 0.7f, snowCover = 0.95f, exposure = 1.15f, neonIntensity = 3.2f,
        };

        public static readonly CityPreset[] All = { Snowfall, Day, Sunset, Night };

        static readonly (string name, Func<CityPreset, Color> value)[] MaterialColors =
        {
            ("_SunColor", p => p.sun),
            ("_SkyZenith", p => p.zenith),
            ("_SkyHorizon", p => p.horizon),
            ("_CloudColor", p => p.clouds),
            ("_FogColor", p => p.fog),
            ("_AbyssColor", p => p.abyss),
            ("_AmbientSky", p => p.ambientSky),
            ("_AmbientGround", p => p.ambientGround),
        };

        static readonly (string name, Func<CityPreset, float> value)[] MaterialFloats =
        {
            ("_CloudCover", p => p.cloudCover),
            ("_FogDensity", p => p.fogDensity),
            ("_FogFalloff", p => p.fogFalloff),
            ("_WindowLit", p => p.windowLit),
            ("_WindowIntensity", p => p.windowIntensity),
            ("_UnderLit", p => p.underLit),
            ("_CarIntensity", p => p.carIntensity),
            ("_SnowAmount", p => p.snowAmount),
            ("_SnowCover", p => p.snowCover),
            ("_Exposure", p => p.exposure),
            ("_NeonIntensity", p => p.neonIntensity),
        };

        public static void Apply(Material m, CityPreset p)
        {
            m.SetVector("_SunDir", p.ShaderSun);
            foreach (var property in MaterialColors) m.SetColor(property.name, property.value(p));
            foreach (var property in MaterialFloats) m.SetFloat(property.name, property.value(p));
            Vector3 o = Gen.CityMeshBuilder.CityOffset;
            m.SetVector("_CityOffset", new Vector4(o.x, o.y, o.z, 0));
            m.SetFloat("_AnchorAltitude", Gen.CityMeshBuilder.AnchorAltitude);
            EditorUtility.SetDirty(m);
        }


        /// <summary>Apply to every city material AND the open scene (ambient, avatar light, snow).</summary>
        public static void ApplyToScene(CityPreset p)
        {
            foreach (var path in CityMaterials)
            {
                var m = AssetDatabase.LoadAssetAtPath<Material>(path);
                if (m != null) Apply(m, p);
            }

            // snowflakes are plain particles: give them the colour the city light would give them
            var snow = GameObject.Find("Snow");
            if (snow != null && snow.TryGetComponent(out ParticleSystem ps))
            {
                var main = ps.main;
                main.startColor = p.SnowColor;
            }

            // Avatars see Unity lighting: approximate the city's light.
            RenderSettings.ambientMode = UnityEngine.Rendering.AmbientMode.Trilight;
            RenderSettings.ambientSkyColor = p.AvatarSky;
            RenderSettings.ambientEquatorColor = p.AvatarEquator;
            RenderSettings.ambientGroundColor = p.AvatarGround;
            var sunGo = GameObject.Find("Sun");
            if (sunGo != null && sunGo.TryGetComponent(out Light l))
            {
                p.GetAvatarSun(out var rotation, out float intensity, out var color);
                l.transform.rotation = rotation;
                l.intensity = intensity;
                l.color = color;
                l.enabled = p.sunVisibility > 0;
            }

            EditorPrefs.SetString("MatrixCocoa.Preset", p.name);
            UnityEditor.SceneManagement.EditorSceneManager.MarkSceneDirty(UnityEngine.SceneManagement.SceneManager.GetActiveScene());
            Debug.Log("[MatrixCocoa] lighting preset: " + p.name);
        }

        /// <summary>Same curve as cityTonemap() in CityCommon.cginc (output is linear).</summary>
        public static Color Tonemap(Color c, float exposure)
        {
            float F(float x) { x *= exposure; return Mathf.Clamp01((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f)); }
            return new Color(F(c.r), F(c.g), F(c.b), 1f);
        }

        public static CityPreset ByName(string n)
        {
            foreach (var p in All) if (string.Equals(p.name, n, System.StringComparison.OrdinalIgnoreCase)) return p;
            return Day;
        }

        [MenuItem("Matrix Cocoa/Lighting/Snowfall (the one true mood)")] static void MSnow() => ApplyToScene(Snowfall);
        [MenuItem("Matrix Cocoa/Lighting/Day")]    static void MDay()    => ApplyToScene(Day);
        [MenuItem("Matrix Cocoa/Lighting/Sunset")] static void MSunset() => ApplyToScene(Sunset);
        [MenuItem("Matrix Cocoa/Lighting/Night")]  static void MNight()  => ApplyToScene(Night);
    }
}
