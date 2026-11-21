// =====================================================================================
//  CityAtmosphere.cginc - sky, clouds, height fog (thick below, thin above) and the
//  falling snow.
// =====================================================================================
#ifndef CITY_ATMOSPHERE_INCLUDED
#define CITY_ATMOSPHERE_INCLUDED

float3 skyColor(float3 ro, float3 rd, bool clouds)
{
    float h = rd.y;
    float3 col = lerp(_SkyHorizon.rgb, _SkyZenith.rgb, pow(saturate(h), 0.45));
    col = lerp(col, _AbyssColor.rgb, saturate(-h * 3.0));

    float sd = saturate(dot(rd, _SunDir.xyz));
    float sunVis = _SunDir.w;
    col += _SunColor.rgb * sunVis * (pow(sd, 8.0) * 0.25 + pow(sd, 64.0) * 0.6);

    if (clouds && h > 0.0)
    {
        // an overcast deck ~2.8 km above the viewer, drifting
        float tc = 2800.0 / max(h, 0.02);
        float2 uv = (ro.xz + rd.xz * tc) / 2600.0 + _Time.y * float2(0.0035, 0.0012);
        float n = fbm2(uv * 2.0);
        float cov = smoothstep(1.0 - _CloudCover, 1.0 - _CloudCover + 0.35, n);
        float3 cc = _CloudColor.rgb * (0.75 + 0.5 * n);
        cc += _SunColor.rgb * sunVis * pow(sd, 6.0) * 0.6 * (1.0 - cov * 0.5);   // silver lining
        float fade = smoothstep(0.0, 0.18, h);
        col = lerp(col, cc, cov * fade);
    }
    // the sun disc, dimmed by clouds/haze
    col += _SunColor.rgb * sunVis * smoothstep(0.99985, 0.99995, sd) * 6.0 * (1.0 - _CloudCover * 0.8);
    return col;
}

// optical depth of exponential height fog from ro along rd for distance t
float fogOpticalDepth(float3 ro, float3 rd, float t)
{
    float a = _FogDensity * exp(clamp(-(ro.y - _AnchorAltitude) / _FogFalloff, -60.0, 60.0));
    float k = rd.y / _FogFalloff;
    if (abs(k * t) < 1e-4) return a * t;
    return a * (1.0 - exp(clamp(-k * t, -80.0, 60.0))) / k;
}
float fogTrans(float3 ro, float3 rd, float t) { return exp(-fogOpticalDepth(ro, rd, t)); }

// Fog colour depends on WHERE along the ray most of the fog was picked up: haze up in
// the open sky is sky-lit, haze deep inside the canyons is shadowed and tinted by the
// glowing depths. We take the height at which transmittance reaches 1/2 (closed form).
float fogHalfHeight(float3 ro, float3 rd, float t)
{
    float a = _FogDensity * exp(clamp(-(ro.y - _AnchorAltitude) / _FogFalloff, -60.0, 60.0));
    float k = rd.y / _FogFalloff;
    const float LN2 = 0.6931;
    float th;
    if (abs(k) < 1e-6) th = LN2 / a;
    else
    {
        float arg = 1.0 - LN2 * k / a;
        th = arg > 0.0 ? -log(arg) / k : 1e9;
    }
    th = min(th, t);
    return ro.y + rd.y * th;
}

float3 fogColor(float3 ro, float3 rd, float t)
{
    float3 c = _FogColor.rgb;
    float sd = saturate(dot(rd, _SunDir.xyz));
    c += _SunColor.rgb * _SunDir.w * (pow(sd, 6.0) * 0.35 + 0.04);
    float y = fogHalfHeight(ro, rd, t);
    c *= lerp(0.55, 1.0, smoothstep(-100.0, 700.0, y));                  // canyon haze is shadowed
    c = lerp(c, _AbyssColor.rgb, smoothstep(150.0, -900.0, y));           // the depths glow
    return c;
}

float3 applyFog(float3 col, float3 ro, float3 rd, float t)
{
    float tr = fogTrans(ro, rd, t);
    return lerp(fogColor(ro, rd, t), col, tr);
}

// --------------------------------------------------------------------------- snow
// World-locked flakes: one flake per cell of a grid that slides upward (so flakes fall),
// walked with a 3D DDA from the eye. Returns premultiplied colour, alpha in .a
float4 snowFlakes(float3 roW, float3 rd, float tHit, float pa, float3 lightCol)
{
    if (_SnowAmount <= 0.001 || _SnowSteps <= 0) return 0;
    const float cell = 1.1;
    float3 shift = float3(_Time.y * 0.35, _Time.y * 1.1, _Time.y * 0.12);   // wind + fall (m/s)
    float3 o = (roW + shift) / cell;
    int3 c = int3(floor(o));
    float3 st = sign(rd);
    float3 inv = 1.0 / max(abs(rd), 1e-5);
    float3 tMaxv = ((float3(c) + max(st, 0.0)) - o) * st * inv;   // in cell units
    float3 tDel = inv;
    float a = 0.0;
    [loop] for (int i = 0; i < _SnowSteps; i++)
    {
        uint hc = hash3i(c);
        if (rndu(hc, 0u) < _SnowAmount)
        {
            float3 jit = float3(rndu(hc, 1u), rndu(hc, 2u), rndu(hc, 3u));
            float ph = rndu(hc, 4u) * 6.283;
            jit.xz += 0.12 * float2(sin(_Time.y * 1.3 + ph), cos(_Time.y * 1.1 + ph));
            float3 fw = (float3(c) + 0.2 + 0.6 * jit) * cell - shift;   // flake, world space
            bool inRoom = all(fw > _RoomMin.xyz) && all(fw < _RoomMax.xyz);
            float3 v = fw - roW;
            float tt = dot(v, rd);
            if (!inRoom && tt > 0.05 && tt < tHit)
            {
                float d2 = max(dot(v, v) - tt * tt, 0.0);
                float r = lerp(0.007, 0.016, rndu(hc, 5u));
                float sg = max(r, tt * pa * 0.7);
                a += (r * r) / (sg * sg) * exp(-d2 / (sg * sg));
            }
        }
        // DDA step
        if (tMaxv.x < tMaxv.y && tMaxv.x < tMaxv.z) { c.x += int(st.x); tMaxv.x += tDel.x; }
        else if (tMaxv.y < tMaxv.z)                 { c.y += int(st.y); tMaxv.y += tDel.y; }
        else                                        { c.z += int(st.z); tMaxv.z += tDel.z; }
    }
    a = saturate(a);
    return float4(lightCol * a, a);
}

#endif
