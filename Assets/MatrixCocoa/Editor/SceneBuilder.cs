using System.Collections.Generic;
using System.IO;
using UnityEditor;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.SceneManagement;

namespace MatrixCocoa.EditorTools
{
    /// <summary>
    /// Matrix Cocoa > Rebuild Scene. Everything under "Matrix Cocoa (generated)" is deleted
    /// and rebuilt; anything you add OUTSIDE that root survives (VRCWorld is created once and
    /// then left alone, so its world settings are yours).
    /// </summary>
    public static class SceneBuilder
    {
        public const string ScenePath = "Assets/MatrixCocoa/Scenes/MatrixCocoa.unity";
        public const string RootName = "Matrix Cocoa (generated)";
        const string MatDir = "Assets/MatrixCocoa/Materials";

        [MenuItem("Matrix Cocoa/Rebuild Scene", priority = 0)]
        public static void Build()
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            OpenOrCreateScene();
            var old = GameObject.Find(RootName);
            if (old != null) Object.DestroyImmediate(old);
            var root = new GameObject(RootName);

            if (!File.Exists(CityTextures.AlbedoPath) || !File.Exists(CityTextures.NormalPath)) CityTextures.Build();
            Directory.CreateDirectory(MatDir);
            Directory.CreateDirectory(GenDir);

            // ---- materials
            var sky = LoadOrCreateMaterial(CityPresets.SkyMat, "MatrixCocoa/CitySky");
            var facade = LoadOrCreateMaterial(CityPresets.FacadeMat, "MatrixCocoa/CityFacade");
            var car = LoadOrCreateMaterial(CityPresets.CarMat, "MatrixCocoa/CityCar");
            var carLights = LoadOrCreateMaterial(CityPresets.CarLightsMat, "MatrixCocoa/CityCarLights");
            facade.SetTexture("_FacadeAlbedo", AssetDatabase.LoadAssetAtPath<Texture2DArray>(CityTextures.AlbedoPath));
            facade.SetTexture("_FacadeNormal", AssetDatabase.LoadAssetAtPath<Texture2DArray>(CityTextures.NormalPath));
            var noise = AssetDatabase.LoadAssetAtPath<Texture2D>(CityTextures.NoisePath);
            if (noise == null) noise = CityTextures.BuildNoise();
            facade.SetTexture("_CityNoise", noise);
            RenderSettings.skybox = sky;
            RenderSettings.fog = false;
            RenderSettings.defaultReflectionMode = UnityEngine.Rendering.DefaultReflectionMode.Skybox;
            RenderSettings.defaultReflectionResolution = 256;

            // ---- the city: meshes + roof height map
            var city = Gen.CityMeshBuilder.Build();
            var hm = SaveAsset(city.heightMap, GenDir + "/CityHeight.asset");
            facade.SetTexture("_CityHeight", hm);
            facade.SetVector("_CityHeightRect", city.heightRect);
            var cityRoot = new GameObject("City");
            cityRoot.transform.SetParent(root.transform);
            var cityMeshes = SaveMeshes(city.chunks, GenDir + "/CityMeshes.asset");
            foreach (var m in cityMeshes)
            {
                var go = MakeRenderer(cityRoot.transform, m, facade);
                // the hovercars bump into the buildings near the station (static mesh colliders)
                if (m.bounds.SqrDistance(Vector3.zero) < CollideRadius * CollideRadius) go.AddComponent<MeshCollider>().sharedMesh = m;
            }

            // ---- traffic
            var traffic = Gen.CityTrafficBuilder.Build();
            var tRoot = new GameObject("Traffic");
            tRoot.transform.SetParent(root.transform);
            var tMeshes = new List<Mesh>(traffic.bodies);
            tMeshes.AddRange(traffic.lights);
            var saved = SaveMeshes(tMeshes, GenDir + "/TrafficMeshes.asset");
            for (int k = 0; k < saved.Count; k++) MakeRenderer(tRoot.transform, saved[k], k < traffic.bodies.Count ? car : carLights);

            // ---- neon
            var signs = Gen.CitySignBuilder.Build();
            var sRoot = new GameObject("Neon");
            sRoot.transform.SetParent(root.transform);
            var sm = SaveMeshes(new List<Mesh> { signs.panels, signs.glows }, GenDir + "/SignMeshes.asset");
            var atlas = ImportSignAtlas();
            var signMat = LoadOrCreateMaterial(CityPresets.SignMat, "MatrixCocoa/CitySign");
            var glowMat = LoadOrCreateMaterial(CityPresets.SignGlowMat, "MatrixCocoa/CitySignGlow");
            signMat.SetTexture("_SignAtlas", atlas);
            glowMat.SetTexture("_SignAtlas", atlas);
            MakeRenderer(sRoot.transform, sm[0], signMat);
            MakeRenderer(sRoot.transform, sm[1], glowMat);

            // A small, solid platform at the city anchor replaces the station.
            var mood = CityPresets.Snowfall;
            var platform = GameObject.CreatePrimitive(PrimitiveType.Cube);
            platform.name = "Spawn Platform";
            platform.transform.SetParent(root.transform, false);
            platform.transform.localPosition = new Vector3(0, 0.25f, 0);
            platform.transform.localScale = new Vector3(12f, 0.5f, 12f);
            var outward = Gen.CityRules.Site.normal;
            var spawn = new GameObject("Spawn").transform;
            spawn.SetParent(root.transform, false);
            spawn.SetPositionAndRotation(new Vector3(0, 0.6f, 0), Quaternion.LookRotation(new Vector3(outward.x, 0, outward.y)));

            // ---- avatar light (follows the preset's sun)
            var sun = new GameObject("Sun");
            sun.transform.SetParent(root.transform);
            var l = sun.AddComponent<Light>();
            l.type = LightType.Directional;
            l.shadows = LightShadows.None;

            BuildSnow(root.transform);
            EnsureVRCWorld(spawn);
            RemoveTemplateLeftovers();
            SetupReferenceCamera(spawn);

            CityPresets.ApplyToScene(mood);
            EnsureInBuildSettings();
            AssetDatabase.SaveAssets();
            EditorSceneManager.SaveScene(SceneManager.GetActiveScene());
            Debug.Log($"[MatrixCocoa] scene rebuilt in {sw.ElapsedMilliseconds} ms: {city.lots} lots, {city.prisms} stages, " +
                      $"{traffic.cars} cars ({traffic.bodyCars} with bodies), {signs.count} signs");
        }

        const string GenDir = "Assets/MatrixCocoa/Generated";

        const float CollideRadius = 2600f;

        static GameObject MakeRenderer(Transform parent, Mesh m, Material mat)
        {
            var go = new GameObject(m.name);
            go.transform.SetParent(parent, false);
            go.AddComponent<MeshFilter>().sharedMesh = m;
            var r = go.AddComponent<MeshRenderer>();
            r.sharedMaterial = mat;
            r.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            r.receiveShadows = false;
            r.lightProbeUsage = UnityEngine.Rendering.LightProbeUsage.Off;
            r.reflectionProbeUsage = UnityEngine.Rendering.ReflectionProbeUsage.Off;
            r.allowOcclusionWhenDynamic = false;
            return go;
        }

        static T SaveAsset<T>(T obj, string path) where T : Object
        {
            AssetDatabase.DeleteAsset(path);
            AssetDatabase.CreateAsset(obj, path);
            return obj;
        }

        // all meshes in one container asset (the first one is the main object)
        static List<Mesh> SaveMeshes(List<Mesh> meshes, string path)
        {
            AssetDatabase.DeleteAsset(path);
            if (meshes.Count == 0) return meshes;
            AssetDatabase.CreateAsset(meshes[0], path);
            for (int k = 1; k < meshes.Count; k++) AssetDatabase.AddObjectToAsset(meshes[k], path);
            AssetDatabase.ImportAsset(path);
            return meshes;
        }

        // the lettering atlas baked by Tools/make_sign_atlas.py: linear data, mipmapped (glow), BC5
        const string SignAtlasPath = "Assets/MatrixCocoa/Textures/SignAtlas.png";
        static Texture2D ImportSignAtlas()
        {
            var imp = (TextureImporter)AssetImporter.GetAtPath(SignAtlasPath);
            if (imp != null)
            {
                imp.textureType = TextureImporterType.Default;
                imp.sRGBTexture = false;
                imp.mipmapEnabled = true;
                imp.wrapMode = TextureWrapMode.Clamp;
                imp.filterMode = FilterMode.Trilinear;
                imp.anisoLevel = 8;
                imp.maxTextureSize = 4096;
                imp.npotScale = TextureImporterNPOTScale.None;
                imp.alphaSource = TextureImporterAlphaSource.None;
                var ps = imp.GetPlatformTextureSettings("Standalone");
                ps.overridden = true; ps.format = TextureImporterFormat.BC5; ps.maxTextureSize = 4096;
                imp.SetPlatformTextureSettings(ps);
                imp.SaveAndReimport();
            }
            return AssetDatabase.LoadAssetAtPath<Texture2D>(SignAtlasPath);
        }

        // ------------------------------------------------------------------ snow
        static void BuildSnow(Transform root)
        {
            var go = new GameObject("Snow");
            go.transform.SetParent(root);
            go.transform.localPosition = new Vector3(0, 30f, 0f);
            var ps = go.AddComponent<ParticleSystem>();
            var main = ps.main;
            main.loop = true; main.prewarm = true;
            main.startLifetime = 36f;
            main.startSpeed = 0f;
            main.startSize = new ParticleSystem.MinMaxCurve(0.025f, 0.055f);
            main.maxParticles = 14000;
            main.simulationSpace = ParticleSystemSimulationSpace.World;
            var em = ps.emission; em.rateOverTime = 380f;
            var sh = ps.shape; sh.shapeType = ParticleSystemShapeType.Box; sh.scale = new Vector3(100f, 1f, 100f);
            var vel = ps.velocityOverLifetime; vel.enabled = true; vel.space = ParticleSystemSimulationSpace.World;
            vel.x = new ParticleSystem.MinMaxCurve(0.3f, 0.45f);
            vel.y = new ParticleSystem.MinMaxCurve(-1.25f, -0.95f);
            vel.z = new ParticleSystem.MinMaxCurve(0.05f, 0.2f);
            var noise = ps.noise; noise.enabled = true; noise.strength = 0.35f; noise.frequency = 0.25f; noise.scrollSpeed = 0.2f;
            var r = go.GetComponent<ParticleSystemRenderer>();
            r.sharedMaterial = AssetDatabase.GetBuiltinExtraResource<Material>("Default-ParticleSystem.mat");
            r.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            r.receiveShadows = false;
        }

        static void OpenOrCreateScene()
        {
            if (SceneManager.GetActiveScene().path == ScenePath) return;
            if (File.Exists(ScenePath)) { EditorSceneManager.OpenScene(ScenePath, OpenSceneMode.Single); return; }
            Directory.CreateDirectory(Path.GetDirectoryName(ScenePath));
            var s = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);
            EditorSceneManager.SaveScene(s, ScenePath);
        }

        static Material LoadOrCreateMaterial(string path, string shader)
        {
            var m = AssetDatabase.LoadAssetAtPath<Material>(path);
            if (m == null)
            {
                m = new Material(Shader.Find(shader));
                AssetDatabase.CreateAsset(m, path);
            }
            else if (m.shader == null || m.shader.name != shader) m.shader = Shader.Find(shader);
            return m;
        }

        // ------------------------------------------------------------------ VRChat
        static void EnsureVRCWorld(Transform spawn)
        {
            var w = GameObject.Find("VRCWorld");
            if (w == null)
            {
                var prefab = AssetDatabase.LoadAssetAtPath<GameObject>("Packages/com.vrchat.worlds/Samples/UdonExampleScene/Prefabs/VRCWorld.prefab");
                if (prefab == null) { Debug.LogWarning("[MatrixCocoa] VRCWorld prefab not found"); return; }
                w = (GameObject)PrefabUtility.InstantiatePrefab(prefab);
                w.name = "VRCWorld";
            }
            // Keep the world descriptor and its settings, but replace any old station spawns.
            w.transform.SetPositionAndRotation(spawn.position, spawn.rotation);
            var desc = w.GetComponent("VRCSceneDescriptor");
            if (desc != null)
            {
                var so = new SerializedObject(desc);
                var spawns = so.FindProperty("spawns");
                if (spawns != null)
                {
                    spawns.arraySize = 1;
                    spawns.GetArrayElementAtIndex(0).objectReferenceValue = w.transform;
                }
                var radius = so.FindProperty("spawnRadius");
                if (radius != null) radius.floatValue = 0f;
                var respawn = so.FindProperty("RespawnHeightY");
                if (respawn != null) respawn.floatValue = -1600f;
                so.ApplyModifiedPropertiesWithoutUndo();
            }
        }

        static void RemoveTemplateLeftovers()
        {
            foreach (var n in new[] { "Floor", "Directional Light" })
            {
                var g = GameObject.Find(n);
                if (g != null && g.transform.parent == null) Object.DestroyImmediate(g);
            }
            if (GameObject.Find("Main Camera") == null)
            {
                var cam = new GameObject("Main Camera") { tag = "MainCamera" };
                var c = cam.AddComponent<Camera>();
                c.nearClipPlane = 0.05f;
                cam.transform.SetPositionAndRotation(new Vector3(0, 1.6f, 0), Quaternion.Euler(0, 90, 0));
            }
        }

        // VRChat copies near/far clip from the descriptor's reference camera: the city is 5 km deep
        static void SetupReferenceCamera(Transform spawn)
        {
            var cam = GameObject.Find("Main Camera");
            if (cam == null) return;
            var c = cam.GetComponent<Camera>();
            c.nearClipPlane = 0.05f;
            cam.transform.SetPositionAndRotation(spawn.position + Vector3.up * 1.6f, spawn.rotation);
            c.farClipPlane = 9000f;
            var w = GameObject.Find("VRCWorld");
            var desc = w != null ? w.GetComponent("VRCSceneDescriptor") : null;
            if (desc == null) return;
            var so = new SerializedObject(desc);
            var p = so.FindProperty("ReferenceCamera");
            if (p != null) { p.objectReferenceValue = cam; so.ApplyModifiedPropertiesWithoutUndo(); }
        }

        static void EnsureInBuildSettings()
        {
            var list = new System.Collections.Generic.List<EditorBuildSettingsScene>(EditorBuildSettings.scenes);
            list.RemoveAll(s => s.path == ScenePath);
            list.Insert(0, new EditorBuildSettingsScene(ScenePath, true));
            EditorBuildSettings.scenes = list.ToArray();
        }
    }
}
