// Sign glow: neon halos shaped like the lettering (the atlas coverage at a blurry mip),
// lightbox/screen panels glowing as rectangles, and coloured light spilling over the wall
// behind blade signs. Additive - fakes bloom in the snowy air without post-processing.
Shader "MatrixCocoa/CitySignGlow"
{
    Properties
    {
        [NoScaleOffset] _SignAtlas ("Sign atlas (R sdf, G coverage)", 2D) = "black" {}
        // ---- shared city block (CityPresets.cs) ----
        [HideInInspector] _CityOffset ("", Vector) = (0, 228, 0, 0)
        [HideInInspector] _AnchorAltitude ("", Float) = 228
        [HideInInspector] _FogDensity ("", Float) = 0.00055
        [HideInInspector] _FogFalloff ("", Float) = 700
        [HideInInspector] _NeonIntensity ("", Float) = 4
        [HideInInspector] _Exposure ("", Float) = 1
    }
    SubShader
    {
        Tags { "RenderType" = "Transparent" "Queue" = "Transparent-20" "IgnoreProjector" = "True" }
        Blend One One
        ZWrite Off
        Cull Off
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 4.0
            #include "UnityCG.cginc"
            #include "Include/CityCommon.cginc"
            #include "Include/CityAtmosphere.cginc"
            #include "Include/CitySigns.cginc"

            struct appdata { float4 vertex : POSITION; float4 uv0 : TEXCOORD0; float4 uv1 : TEXCOORD1; float4 uv2 : TEXCOORD2; float4 uv3 : TEXCOORD3; UNITY_VERTEX_INPUT_INSTANCE_ID };
            struct v2f
            {
                float4 pos : SV_POSITION;
                float4 uv0 : TEXCOORD0;
                nointerpolation float4 rect : TEXCOORD1;
                nointerpolation float3 col : TEXCOORD2;
                nointerpolation float style : TEXCOORD3;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f vert(appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv0 = v.uv0; o.rect = v.uv2;
                float3 eye = cityEye();
                float3 d = worldToCity(mul(unity_ObjectToWorld, v.vertex).xyz) - eye;
                float dist = length(d);
                uint s = (uint)(v.uv1.x + 0.5);
                int style = (int)(v.uv1.y + 0.5);
                o.style = style;
                int look = style == STYLE_SPILL ? (int)(v.uv3.z + 0.5) : style;   // a spill glows in its sign's colour
                o.col = signAvgColor(s, look, (int)(v.uv1.z + 0.5), (int)(v.uv1.w + 0.5)) * signBlink(s)
                      * fogTrans(eye, d / dist, dist) * _NeonIntensity;
                return o;
            }

            float4 frag(v2f i) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                float2 lp = i.uv0.xy, dims = i.uv0.zw;
                int style = (int)(i.style + 0.5);
                float g;
                if (style == STYLE_SPILL)
                {
                    // light thrown on the wall around the blade's bracket line (centre of the quad)
                    float x = (lp.x - dims.x * 0.5) / (dims.x * 0.2);
                    float y = max(abs(lp.y - dims.y * 0.5) - (dims.y * 0.5 - 2.5), 0.0) / 1.2;   // flat along the blade, soft ends
                    g = exp(-x * x - y * y) * 0.06;
                }
                else
                {
                    float2 half_ = dims * 0.5;
                    float2 q = abs(lp - half_) - half_;
                    float dOut = length(max(q, 0.0));
                    float pad = 0.6 * min(dims.x, dims.y) + 2.5;          // = CitySignBuilder.Glow
                    float fall = 0.18 * min(dims.x, dims.y) + 0.6;
                    float rectGlow = exp(-(dOut * dOut) / (fall * fall)) * smoothstep(pad, pad * 0.4, dOut);
                    if (style == STYLE_LIGHTBOX || style == STYLE_SCREEN) g = rectGlow * 0.035;
                    else
                    {
                        // letter-shaped: the coverage at a soft mip, clamped to the sign
                        float2 uv = lerp(i.rect.xy, i.rect.zw, saturate(lp / dims));
                        float cov = _SignAtlas.SampleLevel(sampler_SignAtlas, uv, 4.5).g;
                        g = (cov * 0.45 + 0.015) * rectGlow;
                    }
                }
                float3 c = i.col * g * _Exposure;
                return float4(c / (1.0 + c), 0);
            }
            ENDCG
        }
    }
}
