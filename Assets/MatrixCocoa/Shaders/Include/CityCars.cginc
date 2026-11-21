// =====================================================================================
//  CityCars.cginc - where a car is right now, and what it looks like.
//  Lanes are baked by Editor/Gen/CityTrafficBuilder.cs (see its vertex layout).
// =====================================================================================
#ifndef CITY_CARS_INCLUDED
#define CITY_CARS_INCLUDED

#define CAR_SALOON 0
#define CAR_VAN    1
#define CAR_BUS    2
#define CAR_HAULER 3

// half-length, half-width, lamp height - must match CityTrafficBuilder.Dims
static const float3 CAR_DIMS[4] =
{
    float3(2.4, 0.92, -0.02),
    float3(2.6, 1.02, -0.4),
    float3(5.6, 1.2, -0.55),
    float3(6.3, 1.3, -0.7),
};

struct CarFrame { float3 C; float3 F; float3 L; float scale; };

// uv0 = (lane start x, z, dir x, z), uv1 = (altitude, lane length, speed, phase), uv2 = (kind, paint, seed01, -)
CarFrame carFrame(float4 u0, float4 u1, float4 u2)
{
    float len = u1.y;
    float s = fmod(u1.w + u1.z * _Time.y, len);
    float2 p = u0.xy + u0.zw * s;
    CarFrame f;
    f.C = float3(p.x, u1.x + 0.3 * sin(_Time.y * 0.7 + u2.z * 6.283), p.y);
    f.F = float3(u0.z, 0, u0.w);
    f.L = float3(-u0.w, 0, u0.z);
    f.scale = smoothstep(0.0, 8.0, s) * smoothstep(len, len - 8.0, s);   // appear / vanish at lane ends
    return f;
}

float pixelAngle() { return 2.0 / (abs(unity_CameraProjection._m11) * _ScreenParams.y); }

static const float3 CAR_PAINT[8] =
{
    float3(0.20, 0.03, 0.025),  // oxblood
    float3(0.045, 0.05, 0.055), // graphite
    float3(0.03, 0.045, 0.09),  // navy
    float3(0.5, 0.52, 0.54),    // silver
    float3(0.012, 0.012, 0.014),// black (the party official)
    float3(0.06, 0.1, 0.07),    // bottle green
    float3(0.42, 0.28, 0.05),   // ochre (taxi)
    float3(0.25, 0.26, 0.27),   // gunmetal
};

// q: car-space position (x fwd, y up, z left), nW: world normal, rd: eye ray
float3 shadeCar(int kind, int paintIdx, float seed01, float3 q, float3 nW, float3 rd)
{
    float3 he = CAR_DIMS[kind];
    float3 paint = CAR_PAINT[paintIdx & 7];
    if (kind == CAR_HAULER) paint = lerp(float3(0.16, 0.15, 0.13), paint, 0.3);
    if (kind == CAR_BUS)    paint = q.y > -0.15 ? float3(0.52, 0.47, 0.36) : float3(0.26, 0.035, 0.025);   // cream over red

    // glazing, by region of the hull
    bool glass = false;
    if (kind == CAR_SALOON) glass = q.y > 0.2 && q.y < 0.55 && q.x > -1.6 && q.x < 1.3;
    else if (kind == CAR_VAN) glass = (q.x > 1.7 && q.y > 0.05) || (q.y > 0.25 && q.y < 0.75 && q.x > 0.9);
    else if (kind == CAR_BUS) glass = (q.y > 0.05 && q.y < 0.85 && frac(q.x / 1.6 + 0.5) > 0.08) || (q.x > 5.0 && q.y > -0.2);
    else glass = q.x > 5.2 && q.y > 0.15;
    bool trim = !glass && abs(q.y + (kind == CAR_SALOON ? 0.04 : 0.35)) < 0.04;

    float up = nW.y * 0.5 + 0.5;
    float3 amb = _AmbientSky.rgb * up + _AmbientGround.rgb * 2.5 * (1.0 - up);
    float ndl = saturate(dot(nW, _SunDir.xyz)) * _SunDir.w;
    float3 refl = skyColor(float3(0, 0, 0), reflect(rd, nW), false);
    float fres = 0.04 + 0.96 * pow(1.0 - saturate(dot(-rd, nW)), 5.0);

    if (glass)
    {
        float3 c = refl * (fres * 0.85 + 0.05);
        if (kind == CAR_BUS && seed01 < 0.85) c += float3(1.0, 0.62, 0.3) * 0.3 * _WindowIntensity * saturate(_WindowLit * 2.5);
        else c += float3(0.6, 0.8, 1.0) * 0.02 * _CarIntensity;          // dashboard glow
        return c;
    }
    float3 alb = trim ? paint * 0.35 + 0.02 : paint;
    float3 c = alb * (amb + _SunColor.rgb * ndl) + refl * (fres * 0.6 + 0.03);   // glossy lacquer
    if (nW.y < -0.4)                                                              // warm lift pads underneath
    {
        float2 pp = float2(abs(q.x) - he.x * 0.55, abs(q.z) - he.y * 0.5);
        c += float3(1.0, 0.42, 0.12) * 4.0 * exp(-dot(pp, pp) * 8.0);
    }
    return c;
}

#endif
