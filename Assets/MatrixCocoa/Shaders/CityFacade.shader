// The buildings. Geometry comes from Editor/Gen (CityRules + CityMeshBuilder); this shader
// decides what the concrete, windows, rooms, roofs and the undercity look like.
// Preset values (sun, fog, lit windows...) are written to every city material by
// Editor/CityPresets.cs - the [HideInInspector] block below is that shared contract.
Shader "MatrixCocoa/CityFacade"
{
    Properties
    {
        [NoScaleOffset] _FacadeAlbedo ("Facade albedo (2D array)", 2DArray) = "" {}
        [NoScaleOffset] _FacadeNormal ("Facade normal (2D array)", 2DArray) = "" {}
        [NoScaleOffset] _CityHeight   ("Roof height map", 2D) = "black" {}
        [NoScaleOffset] _CityNoise    ("Tiling noise", 2D) = "gray" {}

        // ---- shared city block (CityPresets.cs) ----
        [HideInInspector] _CityOffset ("", Vector) = (0, 228, 0, 0)
        [HideInInspector] _CityHeightRect ("", Vector) = (0, 0, 1, 1)
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
        [HideInInspector] _AmbientSky ("", Color) = (1, 1.08, 1.2, 1)
        [HideInInspector] _AmbientGround ("", Color) = (0.12, 0.11, 0.1, 1)
        [HideInInspector] _WindowLit ("", Float) = 0.1
        [HideInInspector] _WindowIntensity ("", Float) = 0.9
        [HideInInspector] _UnderLit ("", Float) = 0.8
        [HideInInspector] _CarIntensity ("", Float) = 2.5
        [HideInInspector] _SnowCover ("", Float) = 0.85
        [HideInInspector] _Exposure ("", Float) = 1
    }
    SubShader
    {
        Tags { "RenderType" = "Opaque" "Queue" = "Geometry" }

        // depth prepass: the facade shader is the expensive part, so lay down depth first
        // and shade each pixel once (walls stack up deeply when looking down the canyons)
        Pass
        {
            Tags { "LightMode" = "ForwardBase" }
            ColorMask 0
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "UnityCG.cginc"
            struct appdata { float4 vertex : POSITION; UNITY_VERTEX_INPUT_INSTANCE_ID };
            struct v2f { float4 pos : SV_POSITION; UNITY_VERTEX_OUTPUT_STEREO };
            v2f vert(appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.pos = UnityObjectToClipPos(v.vertex);
                return o;
            }
            float4 frag(v2f i) : SV_Target { return 0; }
            ENDCG
        }

        Pass
        {
            Tags { "LightMode" = "ForwardBase" }
            ZWrite Off
            ZTest LEqual
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 5.0
            #include "UnityCG.cginc"
            #include "Include/CityCommon.cginc"
            #include "Include/CityAtmosphere.cginc"
            #include "Include/CityShading.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float3 normal : NORMAL;
                float4 uv0 : TEXCOORD0;
                float4 uv1 : TEXCOORD1;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct v2f
            {
                float4 pos : SV_POSITION;
                float3 cpos : TEXCOORD0;
                float3 nrm : TEXCOORD1;
                float4 uv0 : TEXCOORD2;
                nointerpolation float4 uv1 : TEXCOORD3;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f vert(appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.pos = UnityObjectToClipPos(v.vertex);
                o.cpos = worldToCity(mul(unity_ObjectToWorld, v.vertex).xyz);
                o.nrm = UnityObjectToWorldNormal(v.normal);
                o.uv0 = v.uv0;
                o.uv1 = v.uv1;
                return o;
            }

            float4 frag(v2f i) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                float3 eye = cityEye();
                float3 v = i.cpos - eye;
                Surf s;
                s.P = i.cpos;
                s.N = normalize(i.nrm);
                s.dist = length(v);
                s.rd = v / s.dist;
                s.u = i.uv0.x; s.len = i.uv0.y;
                s.edgeDist = i.uv0.x;
                s.y0 = i.uv0.z; s.y1 = i.uv0.w;
                s.lotSeed = (uint)(i.uv1.x + 0.5);
                s.seed = (uint)(i.uv1.y + 0.5);
                s.stage = (int)(i.uv1.z + 0.5);
                s.face = (int)(i.uv1.w + 0.5);
                s.foot = max(max(length(ddx(i.cpos)), length(ddy(i.cpos))), 1e-3);
                float2 du = float2(ddx(i.uv0.x), ddy(i.uv0.x)), dy = float2(ddx(i.cpos.y), ddy(i.cpos.y));
                s.foot2 = max(float2(length(du), length(dy)), 1e-3);

                float3 col = shadeSurface(s);
                col = applyFog(col, eye, s.rd, s.dist);
                return float4(cityTonemap(col), 1);
            }
            ENDCG
        }

        // depth only (for the camera depth texture / avatar effects)
        Pass
        {
            Tags { "LightMode" = "ShadowCaster" }
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_shadowcaster
            #include "UnityCG.cginc"
            struct v2f { V2F_SHADOW_CASTER; UNITY_VERTEX_OUTPUT_STEREO };
            v2f vert(appdata_base v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                TRANSFER_SHADOW_CASTER_NORMALOFFSET(o)
                return o;
            }
            float4 frag(v2f i) : SV_Target { SHADOW_CASTER_FRAGMENT(i) }
            ENDCG
        }
    }
}
