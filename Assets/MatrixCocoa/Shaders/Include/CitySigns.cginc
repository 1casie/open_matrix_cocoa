// =====================================================================================
//  CitySigns.cginc - neon signage (placed by Editor/Gen/CitySignBuilder.cs).
//
//  Lettering comes from SignAtlas (Tools/make_sign_atlas.py): R = signed distance field
//  (0.5 = letter edge), G = coverage (its mips = letter-shaped glow). Styles:
//    NEON     glass tubes following the letter strokes (light weights): white-hot cores,
//             coloured tube, light leaking onto the dark backing; pale glass when unlit
//    OUTLINE  a tube running just inside the letter outline (bold display faces), the
//             painted letter face faintly lit by it
//    LIGHTBOX translucent printed panel lit from inside: coloured ink on a glowing panel
//    CHANNEL  rooftop letters: solid lit letter faces, everything else cut away
//    SCREEN   a jumbotron: drifting colour fields, scanlines, a pixel grid, text crawl
//    TRUSS    the steel lattice behind rooftop letters
//    SPILL    (glow shader only) the sign's coloured light washing over the wall
//  Animation per sign: mostly steady (real neon is), some blink or chase, the odd dying letter.
// =====================================================================================
#ifndef CITY_SIGNS_INCLUDED
#define CITY_SIGNS_INCLUDED

#define STYLE_NEON 0
#define STYLE_OUTLINE 1
#define STYLE_LIGHTBOX 2
#define STYLE_CHANNEL 3
#define STYLE_SCREEN 4
#define STYLE_TRUSS 5
#define STYLE_SPILL 6

UNITY_DECLARE_TEX2D(_SignAtlas);
float4 _SignAtlas_TexelSize;   // (1/w, 1/h, w, h), set by Unity

// lightbox colour schemes: panel / ink
static const float3 LB_PANEL[8] =
{
    float3(1.0, 0.97, 0.9),  float3(1.0, 0.98, 0.95), float3(1.0, 0.85, 0.2),  float3(0.9, 0.1, 0.06),
    float3(0.15, 0.35, 0.95), float3(0.1, 0.6, 0.3),  float3(1.0, 0.93, 0.78), float3(1.0, 0.5, 0.1),
};
static const float3 LB_INK[8] =
{
    float3(0.85, 0.05, 0.04), float3(0.02, 0.02, 0.02), float3(0.02, 0.02, 0.02), float3(1.0, 0.97, 0.9),
    float3(1.0, 1.0, 1.0),    float3(1.0, 1.0, 0.95),   float3(0.1, 0.2, 0.7),    float3(0.03, 0.02, 0.02),
};

struct SignIn
{
    float2 lp, dims;     // local position / size (m)
    uint   seed;
    int    style, ca, cb;
    float4 rect;         // atlas rect
    float  units;        // letters (vertical templates), 0 = estimate
    float  part;         // 0 face, 1 housing
};

float2 atlasUV(SignIn s) { return lerp(s.rect.xy, s.rect.zw, saturate(s.lp / s.dims)); }

int letterCount(SignIn s)
{
    if (s.units > 0.5) return int(s.units + 0.5);
    return max(1, int(round(s.dims.x / (s.dims.y * 0.62))));
}
int letterIndex(SignIn s)
{
    int n = letterCount(s);
    float f = s.units > 0.5 ? 1.0 - s.lp.y / s.dims.y : s.lp.x / s.dims.x;
    return clamp(int(f * n), 0, n - 1);
}

// whole-sign on/off (blinking signs) - shared with the glow so halos blink too
float signBlink(uint s)
{
    float mode = rndu(s, 20u);
    if (mode < 0.12) return step(0.35, frac(_Time.y * lerp(0.25, 0.6, rndu(s, 21u)) + rndu(s, 22u)));
    return 1.0;
}
// per-letter on/off: chase signs, dead and dying letters
float letterOn(uint s, int i, int n)
{
    float t = _Time.y;
    float on = signBlink(s);
    float mode = rndu(s, 20u);
    if (mode > 0.12 && mode < 0.22) on = step(float(i) / n, frac(t * 0.2 + rndu(s, 22u)) * 1.3);
    uint ls = hashU(s, uint(i) + 77u);
    float r = rndu(ls, 0u);
    if (r < 0.04) on = 0.0;                                                               // dead tube
    else if (r < 0.07) on *= step(0.25, frac(sin(t * 31.0 + r * 917.0) * 43758.5)) * (0.6 + 0.4 * step(0.5, frac(t * 0.13 + r * 7.0)));  // dying
    return on;
}

// the advert currently on a screen (changes every 7 s) - shared by the face and its glow
uint screenSlot(uint seed) { return hashU(seed, uint(floor((_Time.y + rndu(seed, 5u) * 100.0) / 7.0))); }

float3 signAvgColor(uint seed, int style, int ca, int cb)
{
    if (style == STYLE_LIGHTBOX) return LB_PANEL[ca] * 0.9;
    if (style == STYLE_SCREEN)   return lerp(NEON[pcg(screenSlot(seed)) & 7u], NEON[pcg(screenSlot(seed) + 3u) & 7u], 0.4) * 0.3;
    return NEON[ca];
}

// emission (HDR, before _NeonIntensity) and backing albedo of a sign face; clip() for cut-outs
float3 signFace(SignIn s, out float3 albedo)
{
    float w = s.dims.x, h = s.dims.y;
    float3 A = NEON[s.ca], B = NEON[s.cb];
    albedo = float3(0.03, 0.03, 0.035);
    float2 uv = atlasUV(s);
    float2 sd = UNITY_SAMPLE_TEX2D(_SignAtlas, uv).rg;
    float r = sd.r;
    float fw = max(fwidth(r), 1e-4);
    int n = letterCount(s);
    float on = letterOn(s.seed, letterIndex(s), n);
    float edgeD = min(min(s.lp.x, w - s.lp.x), min(s.lp.y, h - s.lp.y));
    float3 e = 0;

    if (s.style == STYLE_SCREEN)
    {
        // a CRT advertising screen cycling through three "spots" every ~7 s:
        //   0 big glowing lettering on a dark coloured field
        //   1 a text band crawling between two colour stripes
        //   2 pulsing rings and bars (abstract brand graphics)
        float2 q = s.lp / s.dims;
        float t = _Time.y + rndu(s.seed, 5u) * 100.0;
        float slot = floor(t / 7.0);
        float ph = frac(t / 7.0);
        uint ss = screenSlot(s.seed);
        int spot = int(rndu(ss, 0u) * 3.0);
        float3 c1 = NEON[pcg(ss) & 7u], c2 = NEON[pcg(ss + 3u) & 7u];
        float fade = smoothstep(0.0, 0.06, ph) * smoothstep(1.0, 0.94, ph);   // cut to black between spots
        float3 c = c1 * 0.012 * (0.6 + 0.4 * q.y);                           // dark field
        // fit the sign's lettering into a box (keeps its aspect)
        float aspect = (s.rect.z - s.rect.x) / max(s.rect.w - s.rect.y, 1e-5) * (_SignAtlas_TexelSize.z / _SignAtlas_TexelSize.w);
        if (spot == 0)
        {
            float2 box = float2(0.86, 0.86 * w / h / aspect);
            box = box.y > 0.6 ? box * (0.6 / box.y) : box;
            float2 tq = (q - 0.5) / box + 0.5;
            float zoom = 1.0 + 0.04 * ph;                                     // slow push-in
            tq = (tq - 0.5) / zoom + 0.5;
            float r = all(tq > 0.0) && all(tq < 1.0) ? _SignAtlas.SampleLevel(sampler_SignAtlas, lerp(s.rect.xy, s.rect.zw, tq), 0).r : 0.0;
            c += c2 * smoothstep(0.2, 0.5, r) * 0.5 + lerp(c2, 1.0, 0.7) * smoothstep(0.47, 0.55, r) * 1.2;
        }
        else if (spot == 1)
        {
            float band = step(abs(q.y - 0.5), 0.17);
            float stripe = step(abs(abs(q.y - 0.5) - 0.24), 0.04);
            float2 tq = float2(frac(q.x * h / w * aspect * 0.33 - ph * 1.2), (q.y - 0.33) / 0.34);
            float r = band > 0.5 ? _SignAtlas.SampleLevel(sampler_SignAtlas, lerp(s.rect.xy, s.rect.zw, tq), 0).r : 0.0;
            c += c1 * stripe * 0.9 + lerp(c2, 1.0, 0.6) * smoothstep(0.45, 0.55, r) * 1.1 + c2 * band * 0.05;
        }
        else
        {
            float2 p = (q - 0.5) * float2(w / h, 1.0);
            float rr = length(p);
            float ring = abs(frac(rr * 3.0 - ph * 1.5) - 0.5);
            c += c1 * smoothstep(0.08, 0.02, ring) * smoothstep(0.75, 0.2, rr) * 0.9;
            c += c2 * step(frac(q.x * 6.0 + ph * 2.0), 0.18) * step(q.y, 0.12) * 0.8;
        }
        c *= fade;
        // CRT: scanlines, RGB triads up close, a little roll and flicker
        float lines = 0.78 + 0.22 * sin((q.y + t * 0.02) * h * 22.0);
        float3 triad = 1.0;
        if (fwidth(s.lp.x) < 0.03)
        {
            float k = frac(s.lp.x / 0.045);
            triad = float3(step(k, 0.33), step(0.33, k) * step(k, 0.66), step(0.66, k)) * 2.4 + 0.2;
        }
        float flick = 0.95 + 0.05 * sin(t * 50.0);
        float bezel = step(0.35, edgeD);
        albedo = float3(0.03, 0.03, 0.035);
        return c * lines * triad * flick * bezel * 1.1;
    }
    if (s.style == STYLE_TRUSS)
    {
        // a steel lattice: chords, verticals every 1.5 m, diagonals; cut away elsewhere
        float2 p = s.lp;
        float bw = max(0.07, fwidth(p.x) * 0.7);
        float chord = step(abs(p.y - 0.15), bw) + step(abs(p.y - (h - 0.15)), bw) + step(abs(p.y - h * 0.5), bw);
        float vert = step(abs(frac(p.x / 1.5 + 0.5) - 0.5) * 1.5, bw);
        float diag = step(abs(frac((p.x + p.y) / 3.0) - 0.5) * 2.1, bw);
        clip(chord + vert + diag - 0.5);
        albedo = float3(0.1, 0.1, 0.11);
        return A * 0.05;
    }
    if (s.style == STYLE_LIGHTBOX)
    {
        float3 panel = LB_PANEL[s.ca], ink = LB_INK[s.ca];
        float letter = smoothstep(0.5 - fw, 0.5 + fw, r);
        float frame = step(edgeD, 0.12);
        float2 q = s.lp / s.dims;
        float vign = 0.75 + 0.25 * smoothstep(0.0, 0.25, min(min(q.x, 1 - q.x), min(q.y, 1 - q.y)));
        float tubes = 0.92 + 0.08 * cos(q.y * 6.283 * max(1.0, h / 0.6));     // the tubes behind the plastic
        float grime = lerp(0.7, 1.0, smoothstep(0.0, 0.6, q.y + 0.3 * rndu(s.seed, 9u)));
        float3 lit = lerp(panel, ink, letter) * vign * tubes * grime;
        albedo = lerp(lerp(panel, ink, letter) * 0.7, float3(0.06, 0.06, 0.065), frame);
        return lit * 0.55 * (1.0 - frame) * signBlink(s.seed);
    }
    if (s.style == STYLE_CHANNEL)
    {
        clip(r - 0.5 + fw);
        float rim = 1.0 - smoothstep(0.0, 0.08, r - 0.5);
        albedo = float3(0.7, 0.7, 0.68);
        float3 c = A * (1.0 + 0.4 * (s.lp.y / h)) + lerp(A, 1.0, 0.6) * rim * 0.6;
        return c * 0.9 * on;
    }
    // NEON / OUTLINE: bare tubes (cut out) or on a dark backboard
    bool bare = s.part < -0.5;
    if (bare) clip(r - 0.4);                                             // only the tubes and their mounts
    float tube, core;
    if (s.style == STYLE_OUTLINE)
    {
        float d = abs(r - 0.56);
        float tw = 0.032;
        tube = 1.0 - smoothstep(tw - fw, tw + fw, d);
        core = 1.0 - smoothstep(0.0, tw * 0.45 + fw, d);
        e += B * 0.12 * step(0.5, r) * on;                                  // the painted letter face
    }
    else
    {
        tube = smoothstep(0.5 - fw, 0.5 + fw, r);
        core = smoothstep(0.52, 0.52 + max(0.05, 3.0 * fw), r);
    }
    float leak = pow(saturate((r - 0.22) / 0.3), 2.0) * (1.0 - tube);      // light thrown on the backboard
    e += (A * (tube * 1.5 + leak * 0.3) + lerp(A, 1.0, 0.7) * core * 1.4) * on;
    // unlit glass tubes still catch the light
    albedo = lerp(albedo, float3(0.5, 0.52, 0.55), tube * 0.6);
    float frame = step(edgeD, 0.08);
    albedo = lerp(albedo, float3(0.08, 0.08, 0.085), frame);
    return e * (1.0 - frame);
}

// the metal sign housing; lightboxes glow a little through their translucent sides
float3 signHousing(SignIn s, out float3 albedo)
{
    albedo = float3(0.07, 0.07, 0.075) * (0.8 + 0.2 * step(0.5, frac(s.lp.x / 0.6)));
    if (s.style == STYLE_LIGHTBOX) return LB_PANEL[s.ca] * 0.12 * signBlink(s.seed);
    if (s.style == STYLE_SCREEN)   return 0;
    return NEON[s.ca] * 0.04 * signBlink(s.seed);
}

#endif
