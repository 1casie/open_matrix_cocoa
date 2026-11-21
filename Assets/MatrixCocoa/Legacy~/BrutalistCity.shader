// =====================================================================================
//  Matrix Cocoa / Brutalist City
//
//  An infinite brutalist city, ray-traced per pixel and used as the SKYBOX. Rays start
//  at the real (per-eye) camera position, so parallax and stereo are correct in VR.
//
//  Pipeline per pixel (see Include/):
//    CityLayout     streets: jittered highway lattice + divide-and-conquer street cuts
//    CityBuildings  stacked stages per lot + the lot-by-lot ray tracer
//    CityShading    facades, lit windows (interior mapping), roofs, undercity galleries
//    CityTraffic    strata of floating cars
//    CityAtmosphere sky, clouds, height fog, falling snow
//
//  The look per time of day is set by material properties written from
//  Editor/CityPresets.cs (Matrix Cocoa > Lighting > Day / Sunset / Night).
// =====================================================================================
Shader "MatrixCocoa/BrutalistCity"
{
    Properties
    {
        [Header(Layout)]
        _CitySeed       ("City Seed", Float) = 7
        _AnchorAltitude ("Altitude of world y=0 (m)", Float) = 228
        _RoomMin        ("Room AABB min (world)", Vector) = (-3, 0, -3, 0)
        _RoomMax        ("Room AABB max (world)", Vector) = (3, 6, 3, 0)

        [Header(Quality)]
        [IntRange] _MaxSteps      ("Primary lot steps", Range(8, 128)) = 64
        [IntRange] _ShadowSteps   ("Shadow lot steps (0 = off)", Range(0, 48)) = 20
        [IntRange] _TrafficPlanes ("Traffic strata per pixel", Range(0, 64)) = 30
        [IntRange] _SnowSteps     ("Snow cells per pixel", Range(0, 48)) = 22

        [Header(Textures)]
        [NoScaleOffset] _FacadeAlbedo ("Facade albedo (2D array)", 2DArray) = "" {}
        [NoScaleOffset] _FacadeNormal ("Facade normal (2D array)", 2DArray) = "" {}

        [Header(Lighting preset (written by CityPresets.cs))]
        _SunDir          ("Sun dir (xyz) / visibility (w)", Vector) = (0.3, 0.35, 0.88, 1)
        [HDR] _SunColor  ("Sun", Color) = (2.5, 2.3, 2.0, 1)
        [HDR] _SkyZenith ("Sky zenith", Color) = (0.35, 0.42, 0.55, 1)
        [HDR] _SkyHorizon("Sky horizon", Color) = (0.7, 0.74, 0.8, 1)
        [HDR] _CloudColor("Clouds", Color) = (0.62, 0.65, 0.7, 1)
        _CloudCover      ("Cloud cover", Range(0, 1)) = 0.7
        [HDR] _FogColor  ("Fog", Color) = (0.6, 0.64, 0.7, 1)
        _FogDensity      ("Fog density at viewer (1/m)", Float) = 0.0006
        _FogFalloff      ("Fog height falloff (m)", Float) = 650
        [HDR] _AbyssColor("Abyss glow", Color) = (0.35, 0.3, 0.28, 1)
        [HDR] _AmbientSky("Ambient sky", Color) = (0.45, 0.5, 0.58, 1)
        [HDR] _AmbientGround("Ambient ground/abyss", Color) = (0.12, 0.1, 0.09, 1)
        _WindowLit       ("Lit window fraction", Range(0, 1)) = 0.15
        _WindowIntensity ("Window intensity", Float) = 1.5
        _UnderLit        ("Undercity light", Float) = 1
        _CarIntensity    ("Car lights", Float) = 6
        _SnowAmount      ("Falling snow", Range(0, 1)) = 0.35
        _SnowCover       ("Snow cover", Range(0, 1)) = 0.85
        _Exposure        ("Exposure", Float) = 1
    }

    SubShader
    {
        Tags { "Queue" = "Background" "RenderType" = "Background" "PreviewType" = "Skybox" }
        Cull Off ZWrite Off

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 5.0
            #include "UnityCG.cginc"

            #include "Include/CityCommon.cginc"
            #include "Include/CityLayout.cginc"
            #include "Include/CityBuildings.cginc"
            #include "Include/CityAtmosphere.cginc"
            #include "Include/CityShading.cginc"
            #include "Include/CityTraffic.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct v2f
            {
                float4 pos : SV_POSITION;
                float3 dir : TEXCOORD0;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f vert(appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.pos = UnityObjectToClipPos(v.vertex);
                o.dir = mul((float3x3)unity_ObjectToWorld, v.vertex.xyz);
                return o;
            }

            float3 tonemapACES(float3 x)
            {
                return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
            }

            float4 frag(v2f i) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                float3 rd = normalize(i.dir);
                float3 roW = _WorldSpaceCameraPos;
                float3 ro = worldToCity(roW);
                // angular size of one pixel (for anti-aliasing / glare widening)
                float pa = 2.0 / (abs(unity_CameraProjection._m11) * _ScreenParams.y);

                Hit h = traceCity(ro, rd, _MaxSteps, 12000.0, false);
                float3 col;
                if (h.face >= 0)
                {
                    col = shadeHit(h, ro, rd, pa);
                    col = applyFog(col, ro, rd, h.t);
                }
                else
                {
                    col = skyColor(ro, rd, true);
                    col = applyFog(col, ro, rd, rd.y < 0 ? 1e5 : 6000.0);
                }

                Traffic tr = traffic(ro, rd, h.t, pa);
                if (tr.bodyT < 1e8) col = lerp(col, applyFog(tr.body, ro, rd, tr.bodyT), tr.bodyA);
                col += tr.light;
                float tFront = tr.bodyA > 0.5 ? min(h.t, tr.bodyT) : h.t;

                float3 snowLight = _AmbientSky.rgb * 1.6 + _SunColor.rgb * _SunDir.w * 0.35 + _AmbientGround.rgb * 1.5 + 0.02;
                float4 sn = snowFlakes(roW, rd, tFront, pa, snowLight);
                col = col * (1.0 - sn.a) + sn.rgb;

                col = tonemapACES(col * _Exposure);
                // dither against banding in the dark gradients
                float dn = frac(sin(dot(i.pos.xy, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
                col = pow(saturate(pow(col, 1.0 / 2.2) + dn / 255.0), 2.2);   // dither in display space
                return float4(col, 1);
            }
            ENDCG
        }
    }
    Fallback Off
}
