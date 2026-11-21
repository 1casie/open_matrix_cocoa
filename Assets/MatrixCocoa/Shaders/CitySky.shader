// Skybox: sky, drifting overcast, and the same height fog as the buildings, so the city
// melts into the haze at its edge and the bottomless shafts glow from below.
Shader "MatrixCocoa/CitySky"
{
    Properties
    {
        // ---- shared city block (CityPresets.cs) ----
        [HideInInspector] _CityOffset ("", Vector) = (0, 228, 0, 0)
        [HideInInspector] _AnchorAltitude ("", Float) = 228
        [HideInInspector] _SunDir ("", Vector) = (0.3, 0.35, 0.88, 1)
        [HideInInspector] _SunColor ("", Color) = (2.4, 2.25, 2, 1)
        [HideInInspector] _SkyZenith ("", Color) = (0.36, 0.43, 0.55, 1)
        [HideInInspector] _SkyHorizon ("", Color) = (0.66, 0.7, 0.76, 1)
        [HideInInspector] _CloudColor ("", Color) = (0.58, 0.61, 0.66, 1)
        [HideInInspector] _CloudCover ("", Float) = 0.75
        [HideInInspector] _FogColor ("", Color) = (0.56, 0.6, 0.66, 1)
        [HideInInspector] _FogDensity ("", Float) = 0.00055
        [HideInInspector] _FogFalloff ("", Float) = 700
        [HideInInspector] _AbyssColor ("", Color) = (0.26, 0.27, 0.29, 1)
        [HideInInspector] _Exposure ("", Float) = 1
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
            #pragma target 3.5
            #include "UnityCG.cginc"
            #include "Include/CityCommon.cginc"
            #include "Include/CityAtmosphere.cginc"

            struct appdata { float4 vertex : POSITION; UNITY_VERTEX_INPUT_INSTANCE_ID };
            struct v2f { float4 pos : SV_POSITION; float3 dir : TEXCOORD0; UNITY_VERTEX_OUTPUT_STEREO };

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

            float4 frag(v2f i) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                float3 rd = normalize(i.dir);
                float3 ro = cityEye();
                float3 col = skyColor(ro, rd, true);
                col = applyFog(col, ro, rd, rd.y < 0 ? 1e5 : 9000.0);
                return float4(cityTonemap(col), 1);
            }
            ENDCG
        }
    }
}
