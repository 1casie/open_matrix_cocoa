// Car bodies: sleek lofted hulls (Editor/Gen/CityTrafficBuilder.cs -> CarHull) moved along
// their lanes here in the vertex shader. They shrink away between ~260 and ~400 m, where the
// lights-only representation (CityCarLights) carries on alone.
Shader "MatrixCocoa/CityCar"
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
        [HideInInspector] _AmbientSky ("", Color) = (1, 1.08, 1.2, 1)
        [HideInInspector] _AmbientGround ("", Color) = (0.12, 0.11, 0.1, 1)
        [HideInInspector] _WindowLit ("", Float) = 0.1
        [HideInInspector] _WindowIntensity ("", Float) = 0.9
        [HideInInspector] _CarIntensity ("", Float) = 2.5
        [HideInInspector] _Exposure ("", Float) = 1
    }
    SubShader
    {
        Tags { "RenderType" = "Opaque" "Queue" = "Geometry+10" }
        Pass
        {
            Tags { "LightMode" = "ForwardBase" }
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 4.0
            #include "UnityCG.cginc"
            #include "Include/CityCommon.cginc"
            #include "Include/CityAtmosphere.cginc"
            #include "Include/CityCars.cginc"

            struct appdata
            {
                float4 vertex : POSITION; float3 normal : NORMAL;
                float4 uv0 : TEXCOORD0; float4 uv1 : TEXCOORD1; float4 uv2 : TEXCOORD2;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct v2f
            {
                float4 pos : SV_POSITION;
                float3 wpos : TEXCOORD0;
                float3 nrm : TEXCOORD1;
                float3 q : TEXCOORD2;
                nointerpolation float3 info : TEXCOORD3;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f vert(appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                CarFrame f = carFrame(v.uv0, v.uv1, v.uv2);
                float lod = 1.0 - smoothstep(260.0, 400.0, distance(f.C, _WorldSpaceCameraPos));
                float k = f.scale * lod;
                float3 p = v.vertex.xyz;
                float3 w = f.C + (f.F * p.x + float3(0, p.y, 0) + f.L * p.z) * k;
                o.pos = UnityWorldToClipPos(w);
                o.wpos = w;
                o.nrm = f.F * v.normal.x + float3(0, v.normal.y, 0) + f.L * v.normal.z;
                o.q = p;
                o.info = v.uv2.xyz;
                return o;
            }

            float4 frag(v2f i) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                float3 eye = cityEye();
                float3 P = worldToCity(i.wpos);
                float3 v = P - eye; float d = length(v); float3 rd = v / d;
                float3 c = shadeCar((int)(i.info.x + 0.5), (int)(i.info.y + 0.5), i.info.z, i.q, normalize(i.nrm), rd);
                c = applyFog(c, eye, rd, d);
                return float4(cityTonemap(c), 1);
            }
            ENDCG
        }
    }
}
