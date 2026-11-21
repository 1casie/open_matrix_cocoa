// Neon sign faces and housings (Editor/Gen/CitySignBuilder.cs). Opaque with cut-outs for
// bare letters / trusses; fogged and tone-mapped like the rest of the city.
Shader "MatrixCocoa/CitySign"
{
    Properties
    {
        [NoScaleOffset] _SignAtlas ("Sign atlas (R sdf, G coverage)", 2D) = "black" {}
        // ---- shared city block (CityPresets.cs) ----
        [HideInInspector] _CityOffset ("", Vector) = (0, 228, 0, 0)
        [HideInInspector] _AnchorAltitude ("", Float) = 228
        [HideInInspector] _SunDir ("", Vector) = (0.3, 0.35, 0.88, 1)
        [HideInInspector] _SunColor ("", Color) = (2.4, 2.25, 2, 1)
        [HideInInspector] _FogColor ("", Color) = (0.56, 0.6, 0.66, 1)
        [HideInInspector] _FogDensity ("", Float) = 0.00055
        [HideInInspector] _FogFalloff ("", Float) = 700
        [HideInInspector] _AbyssColor ("", Color) = (0.26, 0.27, 0.29, 1)
        [HideInInspector] _AmbientSky ("", Color) = (1, 1.08, 1.2, 1)
        [HideInInspector] _AmbientGround ("", Color) = (0.12, 0.11, 0.1, 1)
        [HideInInspector] _NeonIntensity ("", Float) = 4
        [HideInInspector] _Exposure ("", Float) = 1
    }
    SubShader
    {
        Tags { "RenderType" = "TransparentCutout" "Queue" = "AlphaTest" }
        Cull Off
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
            #include "Include/CitySigns.cginc"

            struct appdata
            {
                float4 vertex : POSITION; float3 normal : NORMAL;
                float4 uv0 : TEXCOORD0; float4 uv1 : TEXCOORD1; float4 uv2 : TEXCOORD2; float4 uv3 : TEXCOORD3;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct v2f
            {
                float4 pos : SV_POSITION;
                float3 wpos : TEXCOORD0;
                float4 uv0 : TEXCOORD1;
                nointerpolation float4 info : TEXCOORD2;
                nointerpolation float4 rect : TEXCOORD3;
                nointerpolation float4 extra : TEXCOORD4;
                float3 nrm : TEXCOORD5;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f vert(appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.pos = UnityObjectToClipPos(v.vertex);
                o.wpos = mul(unity_ObjectToWorld, v.vertex).xyz;
                o.uv0 = v.uv0; o.info = v.uv1; o.rect = v.uv2; o.extra = v.uv3; o.nrm = v.normal;
                return o;
            }

            float4 frag(v2f i, fixed facing : VFACE) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                SignIn s;
                s.lp = i.uv0.xy; s.dims = i.uv0.zw;
                s.seed = (uint)(i.info.x + 0.5); s.style = (int)(i.info.y + 0.5);
                s.ca = (int)(i.info.z + 0.5); s.cb = (int)(i.info.w + 0.5);
                s.rect = i.rect; s.units = i.extra.y; s.part = i.extra.x;
                float3 alb;
                float3 e = s.part > 0.5 ? signHousing(s, alb) : signFace(s, alb);
                float3 n = normalize(i.nrm) * (facing > 0 ? 1 : -1);
                float3 c = alb * (_AmbientSky.rgb * (0.5 + 0.3 * n.y) + _AmbientGround.rgb * 1.5
                                  + _SunColor.rgb * saturate(dot(n, _SunDir.xyz)) * _SunDir.w)
                         + e * _NeonIntensity;
                float3 eye = cityEye();
                float3 v = worldToCity(i.wpos) - eye; float d = length(v);
                c = applyFog(c, eye, v / d, d);
                return float4(cityTonemap(c), 1);
            }
            ENDCG
        }
    }
}
