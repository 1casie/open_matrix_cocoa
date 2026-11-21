// Car head/tail lamps for EVERY car (near and far): two glare-widened lamps per quad,
// additive, depth-tested against the buildings. Far away this is all that is left of the
// traffic - the layered rivers of white and red.
Shader "MatrixCocoa/CityCarLights"
{
    Properties
    {
        // ---- shared city block (CityPresets.cs) ----
        [HideInInspector] _CityOffset ("", Vector) = (0, 228, 0, 0)
        [HideInInspector] _AnchorAltitude ("", Float) = 228
        [HideInInspector] _SunDir ("", Vector) = (0.3, 0.35, 0.88, 1)
        [HideInInspector] _FogColor ("", Color) = (0.56, 0.6, 0.66, 1)
        [HideInInspector] _FogDensity ("", Float) = 0.00055
        [HideInInspector] _FogFalloff ("", Float) = 700
        [HideInInspector] _CarIntensity ("", Float) = 2.5
        [HideInInspector] _Exposure ("", Float) = 1
    }
    SubShader
    {
        Tags { "RenderType" = "Transparent" "Queue" = "Transparent-10" "IgnoreProjector" = "True" }
        Blend One One
        ZWrite Off
        Cull Off
        Offset -1, -1
        Pass
        {
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
                float4 vertex : POSITION;
                float4 uv0 : TEXCOORD0; float4 uv1 : TEXCOORD1; float4 uv2 : TEXCOORD2;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };
            struct v2f
            {
                float4 pos : SV_POSITION;
                float3 wpos : TEXCOORD0;
                float3 lampA : TEXCOORD1;
                float3 lampB : TEXCOORD2;
                float3 col : TEXCOORD3;
                float  r : TEXCOORD4;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            v2f vert(appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_OUTPUT(v2f, o);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                CarFrame f = carFrame(v.uv0, v.uv1, v.uv2);
                int kind = (int)(v.uv2.x + 0.5);
                float3 dm = CAR_DIMS[kind];
                float s = f.scale;
                bool head = v.vertex.z > 0.5;
                float3 lc = f.C + (f.F * (head ? dm.x + 0.08 : -dm.x - 0.08) + float3(0, dm.z, 0)) * s;
                float3 axis = f.L * dm.y * 0.72 * s;
                float3 toEye = _WorldSpaceCameraPos - lc;
                float dist = length(toEye);
                toEye /= dist;
                float pa = pixelAngle();
                float r = kind >= CAR_BUS ? 0.16 : 0.11;
                float R = max(r, dist * pa * 0.8) * 3.0;            // quad half-size: 3 sigma of the glare
                float3 camR = UNITY_MATRIX_V[0].xyz, camU = UNITY_MATRIX_V[1].xyz;
                float3 w = lc + axis * v.vertex.x + (camR * v.vertex.x + camU * v.vertex.y) * R;
                o.pos = UnityWorldToClipPos(w);
                o.wpos = w;
                o.lampA = lc + axis; o.lampB = lc - axis;
                float facing = saturate(dot(head ? f.F : -f.F, toEye));
                float3 tint = head ? (v.uv2.z < 0.3 ? float3(0.72, 0.85, 1.0) : float3(1.0, 0.93, 0.8))   // xenon or halogen
                                   : float3(1.0, 0.04, 0.02) * 0.8;
                float tr = fogTrans(worldToCity(_WorldSpaceCameraPos), -toEye, dist);
                o.col = tint * (0.25 + 0.75 * facing * facing) * _CarIntensity * s * tr;
                o.r = r;
                return o;
            }

            float lampGlow(float3 Lp, float3 eye, float3 rd, float r, float pa)
            {
                float3 v = Lp - eye;
                float tt = max(dot(v, rd), 1e-3);
                float d2 = max(dot(v, v) - tt * tt, 0.0);
                float sg = max(r, tt * pa * 0.8);
                return pow((r * r) / (sg * sg), 0.8) * exp(-d2 / (sg * sg));
            }

            float4 frag(v2f i) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(i);
                float3 eye = _WorldSpaceCameraPos;
                float3 rd = normalize(i.wpos - eye);
                float pa = pixelAngle();
                float e = lampGlow(i.lampA, eye, rd, i.r, pa) + lampGlow(i.lampB, eye, rd, i.r, pa);
                float3 c = i.col * e * _Exposure;
                return float4(c / (1.0 + c), 0);   // soft clip: additive on top of the tone-mapped scene
            }
            ENDCG
        }
    }
}
