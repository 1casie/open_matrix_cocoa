# open_matrix_cocoa

A city-generation project for VRChat (Unity **2022.3.22f1**, VRChat Worlds SDK **3.10.6**,
built-in render pipeline, linear colour). It generates a snowed-in, neon-soaked brutalist city
with buildings, flying traffic and signs.

The scene uses a small spawn platform in place of the lounge, garage and interactive props.

Clone with Git LFS installed: the generated traffic and sign meshes are stored in LFS.
Restore the VRChat packages with VRChat Creator Companion or VPM before opening the project.

## How it works

The city is **generated in C#** in the editor and baked into meshes. The **shaders** decide what
everything looks like. (The first version ray-traced the whole city in a skybox shader. It looked
the same, but cost ~280 ms per eye in VR. It's archived in `Assets/MatrixCocoa/Legacy~`, which Unity
ignores.)

City meshes and their materials are generated in the editor; performance depends on the scene
and hardware.

| What | Where |
| --- | --- |
| **Rules**: streets, lots, building stages (the single source of truth) | `Editor/Gen/CityRules.cs` |
| Building meshes + roof height map | `Editor/Gen/CityMeshBuilder.cs` |
| Traffic lanes + car meshes (4 sleek hull kinds) | `Editor/Gen/CityTrafficBuilder.cs` |
| Neon signs: placement | `Editor/Gen/CitySignBuilder.cs` |
| Scene generator (menu: Matrix Cocoa > Rebuild Scene) | `Editor/SceneBuilder.cs` |
| Day / Sunset / Night values | `Editor/CityPresets.cs` |
| Facades, windows, roofs, undercity | `Shaders/CityFacade.shader` + `Include/CityShading.cginc` |
| Sky + fog | `Shaders/CitySky.shader` + `Include/CityAtmosphere.cginc` |
| Cars (bodies / lights) | `Shaders/CityCar.shader`, `CityCarLights.shader`, `Include/CityCars.cginc` |
| Neon (faces + housings / glows) | `Shaders/CitySign.shader`, `CitySignGlow.shader`, `Include/CitySigns.cginc` |
| Sign lettering atlas (words, fonts) | `Tools/make_sign_atlas.py` -> `Assets/MatrixCocoa/Textures/SignAtlas.png/.json` |
| Shared uniforms, hashes, neon palette, tone curve | `Shaders/Include/CityCommon.cginc` |
| Review shots / benchmark / iteration | `Editor/CityCapture.cs`, `CityBench.cs`, `CityDev.cs` |
| Poly Haven textures (CC0) | `Tools/fetch_polyhaven.py` -> `Assets/ThirdParty/PolyHaven` |
| Texture arrays + tiling noise | `Editor/CityTextures.cs` -> `Assets/MatrixCocoa/Textures` |

Generated files (`Assets/MatrixCocoa/Generated/*`) are rebuilt by **Rebuild Scene**: don't edit them.

## The city

1. **Streets.** A jittered lattice (`CityRules.Block` = 720 m). Each row and column line is a
   highway or a boulevard for its whole length. Each lattice quad is cut recursively (divide and
   conquer) into avenue, street, lane and alley. The cuts meet in T-junctions, so no more than 4
   roads meet anywhere.
2. **Buildings.** Each lot is a stack of stages:
   - Stage 0 rises from 2.6 km down (lost in the fog).
   - Stages 1 and 2 set back and sometimes split around a sky-street.
   - Stage 3 and above are plain set-back towers.

   Each stage is 10–100 floors, bimodal around 30 and around 68, and each further stage is rarer.
   About 2% of lots are "titans" with up to 8 stages; about 4.5% are empty shafts into the abyss.
   Buildings are generated out to 5.2 km.
3. **Facades** (`CityShading.cginc`). Five brutalist families: ribbon, grid, fins, monolith,
   loggia. They add service-shaft piers and technical floors.
   - Windows have depth (reveals with snowy sills, interior-mapped rooms, curtains) and
     derivative-based anti-aliasing.
   - Far away, blocks of lit windows collapse into single bright dots that carry their combined
     light.
   - Below street level, walls become the **undercity**: deep galleries and tunnels lit sodium or
     neon (the side-rooms that go down forever).
4. **Light.** Sun shadows and canyon occlusion are traced through a 2048² roof height map
   (`_CityHeight`), so long sunset shadows don't depend on VRChat's shadow distance. Lit windows
   follow a noise field times `_WindowLit`, with incandescent, tube, TV-blue and neon lamps. The
   fog colour depends on how deep the fog was picked up, so the canyons darken and the depths glow.
5. **Traffic.** Cars fly in strata every 16 m, and only some strata of each street carry traffic.
   Density falls with altitude: rivers of white and red that thicken downward.
   - Every car within 1.35 km has lamps (glare quads): white or xenon headlights, red tail
     lights. No neon on cars (on purpose).
   - Cars within ~380 m also get a body (saloon, van, two-tone bus, freight hauler), which fades
     out by ~400 m.
   - Motion happens in the vertex shader; each car wraps along its own lane.
6. **Neon.** About 19k signs within 1.1 km, clustered by "entertainment district" noise and
   concentrated near eye level and down into the depths. Kinds:
   - vertical box blades jutting from walls
   - wall boards (lightboxes, or bare tube letters)
   - rare CRT jumbotrons cycling through ads
   - rooftop channel letters on steel trusses

   The lettering is real text from `Tools/make_sign_atlas.py`: about 300 templates of invented
   Japanese / Kowloon Chinese / Soviet Cyrillic / English shop words. They are baked from OFL fonts
   (Noto Sans/Serif JP, Oswald, Russo One; licences in `Tools/fonts`) into a distance-field atlas.
   - Styles: tube neon (white-hot cores; pale glass when unlit), outline neon, translucent
     lightboxes, and channel letters.
   - Each wall keeps a list of occupied rectangles, so signs never overlap, and every sign fits
     its wall.
   - Glow: a letter-shaped halo (the atlas coverage at a blurry mip), plus a coloured spill of
     light on the wall behind each blade. No post-processing.
   - To add words, edit the lists in `make_sign_atlas.py`, run it, then **Rebuild Scene**.

## Menu: Matrix Cocoa

- **Rebuild Scene**: regenerates everything under `Matrix Cocoa (generated)` in
  `Assets/MatrixCocoa/Scenes/MatrixCocoa.unity`. Anything outside that root survives.
  `VRCWorld` is created once and then left alone, but its spawn point and reference camera
  are set on each build.
- **Lighting > Day / Sunset / Night**: writes a preset into every city material (the
  `[HideInInspector]` "shared city block" in each shader), plus scene ambient, the avatar "Sun"
  light and the snowflake colour.
- **Capture Review Shots**: renders `CityCapture.Shots` to `Captures/`.
  `python Tools/contact_sheet.py night_highway night_down ...` tiles them into
  `Captures/_sheet.png`.
- **Rebuild Texture Arrays**: run after changing the textures in `fetch_polyhaven.py` (it also
  rebuilds the noise texture).

## Iterating via the Unity MCP bridge

```
MatrixCocoa.EditorTools.SceneBuilder.Build();                              // regenerate
MatrixCocoa.EditorTools.CityDev.Iterate("Night", "highway,down,cars")      // shaders + shots
MatrixCocoa.EditorTools.CityBench.Run(2016, 2240, 6, "Night")              // ms per eye
```

If you edit a preset in `CityPresets.cs`, let Unity recompile before capturing. Otherwise the shots
use the old values.

## Third-party assets and credits

- City facade textures are from Poly Haven under CC0; see
  `Assets/ThirdParty/PolyHaven/CREDITS.md`.
- The sign atlas uses OFL fonts; license files are in `Tools/fonts`.
- VRChat SDK and other packages have their own licenses.

The project is licensed under the MIT License; see `LICENSE`. Third-party assets and packages
retain their respective licenses.
