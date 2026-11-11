# Dynamic Sky artwork

The demo surfaces, conifer foliage, snow, and splash artwork were generated with the built-in ImageGen tool. The Godot files use the generated images as material inputs. Atmospheric lookup tables and cloud noise volumes are numerical data baked by the renderer's [texture generator](../addons/dynamic_sky/rendering/tools/generate_sky_textures.py).

| Asset | Saved image |
| --- | --- |
| Spruce bough with alpha | [spruce_bough.png](../addons/dynamic_sky/demo/materials/spruce_bough.png) |
| Slate terrace | [slate_flagstone.png](../addons/dynamic_sky/demo/materials/slate_flagstone.png) |
| Alpine scree and moss | [alpine_scree.png](../addons/dynamic_sky/demo/materials/alpine_scree.png) |
| Weathered larch | [weathered_larch.png](../addons/dynamic_sky/demo/materials/weathered_larch.png) |
| Standing-seam zinc | [standing_seam_zinc.png](../addons/dynamic_sky/demo/materials/standing_seam_zinc.png) |
| Four snow aggregates with alpha | [snowflake_atlas.png](../addons/dynamic_sky/precipitation/snowflake_atlas.png) |
| Packed sharp/blur air-snow atlas | [snow_sheet.png](../addons/dynamic_sky/precipitation/snow/textures/snow_sheet.png) |
| Four rain impact stages with alpha | [rain_splash_atlas.png](../addons/dynamic_sky/precipitation/rain_splash_atlas.png) |
| Fresh alpine powder | [snowpack.png](../addons/dynamic_sky/demo/materials/masters/snowpack.png) |
| Spruce bark | [spruce_bark.png](../addons/dynamic_sky/demo/materials/masters/spruce_bark.png) |
| Alpine limestone | [alpine_rock.png](../addons/dynamic_sky/demo/materials/masters/alpine_rock.png) |
| Alpine meadow ground | [alpine_meadow.png](../addons/dynamic_sky/demo/materials/masters/alpine_meadow.png) |
| Ground-cover foliage with alpha | [alpine_groundcover_atlas.png](../addons/dynamic_sky/demo/materials/alpine_groundcover_atlas.png) |
| Panning cloud density master | [dynamic_2d_cloud_map.png](../addons/dynamic_sky/rendering/cloud_modes/dynamic_2d_cloud_map.png) |
| Static cloud dome master | [static_cloud_dome_map.png](../addons/dynamic_sky/rendering/cloud_modes/static_cloud_dome_map.png) |

## Packed air-snow atlas

The falling-snow atlas was authored with the built-in ImageGen tool. Its native saved image is 887 × 1774 pixels, arranged as two columns and two rows. Green holds four distinct, irregular sharp aggregate masks; blue holds the corresponding defocused profiles; red is unused and alpha is opaque. It is packed linear data, rather than a color albedo or an alpha cutout. Godot imports it losslessly at 64 × 128 with mipmaps, matching the reference sheet's sampling scale. This image is separate from both the older optional contact-flake atlas and the 4K surface snowpack maps. [Packed atlas](../addons/dynamic_sky/precipitation/snow/textures/snow_sheet.png) · [Import settings](../addons/dynamic_sky/precipitation/snow/textures/snow_sheet.png.import)

The original Unreal sheet was inspected and loaded transiently for a source-versus-original-art QA comparison. It is retained only in the temporary audit folder, outside the project. The shipping atlas contains new generated shapes; it is not a copy or a pixel-identical reconstruction of those cells. The final built-in ImageGen output was `01a1c71c-3431-7cb0-b745-fe718d6c60be/exec-38ad0d5d-1faa-4190-9acc-054421880309.png` beneath the local generated-images directory.

```text
Asset type: original packed sharp/blur snow-particle atlas, portrait 1:2, two columns and two rows.
Primary request: four distinct irregular compact ice-grain aggregates. Preserve the 2×2 portrait arrangement and each blue defocused profile. Increase the green sharp-mask density to about 45 percent of each cell, using dense elongated porous clumps with nuanced green intensity, granular internal structure, and ragged asymmetric edges.
Packing: green is the sharp silhouette; blue is its softly blurred profile; red is zero; background is black; alpha is opaque. Keep cells independent with generous black margins and a square-sprite silhouette after each portrait cell is mapped onto the particle.
Constraints: no stars, sixfold crystals, snowflake icons, decorative symmetry, large empty holes, text, borders, premultiplied transparency, or third-party artwork.
```

## 4K material bake

The built-in ImageGen tool produced 1254 × 1254 material masters. The reproducible bake prepares 4096 × 4096 lossless WebP albedo, tangent normals, and packed ORM for eight material sets, including alpine meadow. Albedo uses periodic-plus-smooth edge conditioning and wrapped Lanczos resampling. Normal maps use a wrapped Sobel gradient over a multiscale relief estimate with seeded microdetail. Ambient occlusion comes from a sampled heightfield horizon. Roughness uses material-specific ranges, and metalness comes from the authored substrate. Snow, rock, and wood are dielectric. The zinc roof has a metallic response. The 4K output is a derived texture size. Relief, AO, and roughness are estimates derived from generated artwork and authored physical parameters. [Bake script](../addons/dynamic_sky/demo/materials/bake_materials.py) · [Moisan's periodic decomposition paper](https://helios2.mi.parisdescartes.fr/~moisan/papers/2009-11r.pdf)

Godot imports the 4K color and ORM maps as BC7 and the tangent normals as BC5. All use mipmaps. The snow set is shared by the reusable surface material. [Demo PBR maps](../addons/dynamic_sky/demo/materials/pbr) · [Snowpack maps](../addons/dynamic_sky/surfaces/textures)

The separate geological bake uses the same alpine-rock master and its albedo alignment. It filters logarithmic luminance at 8, 48, and 256 pixels to estimate broader shelves and fractures over a 32 m tile, with a 0.42 m relief amplitude. It produces an additional 4096 × 4096 normal and nonmetallic ORM pair. Terrain samples that pair at geological scale alongside the fine rock material, and its snow shading retains part of the broad substrate relief. The saved boulder material also uses the pair at its independently authored scale. These maps affect lighting and surface response over the saved geometry. [Geological bake](../addons/dynamic_sky/demo/materials/bake_rock_macro.py) · [Terrain shader](../addons/dynamic_sky/demo/landscape/terrain.gdshader) · [Boulder material](../addons/dynamic_sky/demo/materials/alpine_boulder.tres)

The meadow master feeds both the terrain PBR bake and the ground-cover blade material, keeping their color source consistent. The 1254 × 1254 RGBA ground-cover atlas supplies the low-shrub material. Its alpha defines leaf silhouettes on the authored mesh. [Meadow master](../addons/dynamic_sky/demo/materials/masters/alpine_meadow.png) · [Ground-cover material](../addons/dynamic_sky/demo/landscape/vegetation/ground_cover_material.tres) · [Shrub material](../addons/dynamic_sky/demo/landscape/vegetation/low_shrub_material.tres)

## Spruce bough

```text
Use case: photorealistic-natural
Asset type: original alpha-masked conifer foliage card for a realistic 3D alpine environment
Primary request: generate a single natural gray-green alpine spruce bough photographed broadside from slightly above, isolated on real alpha transparency. It will be placed on tapered branches of a full 3D tree.
Composition/framing: square output. One thin brown woody stem enters at center-left and extends rightward to a delicate asymmetrical point. Six or seven irregular sprays of individual short spruce needles spread above and below, with clearly open transparent gaps between sprays and fine distinct needle silhouettes. Entire bough fits inside frame with margins; root on left, tip on right.
Lighting/mood: flat cool overcast, clean texture photography and neutral diffuse albedo response for dynamic lighting. Natural dark emerald, desaturated blue-green and muted cedar-brown. Sharp but lifelike real needle structure.
Constraints: genuinely transparent PNG with clean true alpha, no ground shadow, no checkerboard, no text, no whole tree, no opaque shapes behind needles, no stylized geometry.
```

## Slate flagstone

```text
Use case: photorealistic-natural
Asset type: original seamless square albedo texture for a game mountain observatory terrace
Primary request: overhead material scan of irregular weather-worn large slate flagstones laid by hand with hairline gray joints. Surface is mostly quiet charcoal, neutral blue-gray and subtle weathered brown. Each stone has subtle anisotropic slate grain, pale cleavage marks, tiny chips and granular specks with believable scale.
Composition/framing: edge-to-edge orthographic straight-down square material swatch, around three meters of surface across. Sparse staggered asymmetric joins, moderate contrast, repeat seamlessly on all four edges.
Lighting/mood: perfectly diffuse flat neutral exposure, dry appearance, no directional lighting or baked glare. Museum-quality real material, nothing like an illustrated grid.
Constraints: no border, no text, no hard dark mortar lines, no vignetting, no props, no silhouettes, no cast shadows. Must read cleanly under dynamic wet and dry shaders.
```

## Alpine scree

```text
Use case: photorealistic-natural
Asset type: original tileable diffuse terrain texture for a real-time alpine ridge scene
Primary request: high quality orthographic overhead material scan of alpine scree ground where broken gray limestone and weathered granite chips meet sparse dark olive moss and gritty charcoal-taupe soil, near a mountain treeline. Small sharp aggregate and fragmented flattish stones with genuine color variation.
Composition/framing: square, flat straight-down color swatch, no horizon, edge-to-edge cover and tileable with edges that match. Fine detail reads from 1m and a relatively homogeneous distribution avoids obvious repeated motifs at long range. Approximate coverage 4 meters per tile.
Lighting/mood: flat diffuse natural ambient, neutral exposure, photographic realism with no cast light or hard shadows.
Constraints: no objects, border, lettering, hardcoded wet highlights, panorama, distant scene, large dominant feature or repeating grid.
```

## Weathered larch

```text
Use case: photorealistic-natural
Asset type: original seamless albedo texture for the timber exterior of a remote alpine observatory in a realistic 3D game
Primary request: scan-like straight-on close-up of tightly fitted vertical weathered larch boards, muted warm umber and weathered silver-brown grain, a few subtle knots, worn fiber ridges, and tight understated seams. Real durable mountain construction, slightly old, finely detailed.
Composition/framing: square texture, uniform edge-to-edge top-down or straight orthographic view, boards continue through the top and bottom; all four edges should tile. A roughly two meter wide material repeat.
Lighting/mood: perfectly flat diffuse light with no baked highlights, shadows or ambient occlusion. Neutral real-world color, natural subtle variations.
Constraints: no sign, lettering, hardware, nails as dominant motifs, framing, perspective, vignette, dark grid, or props.
```

## Standing-seam zinc

```text
Use case: photorealistic-natural
Asset type: original tileable diffuse material for standing-seam metal roofing on a small alpine shelter
Primary request: orthographic material scan of low-gloss charcoal-gray preweathered zinc roofing. Long vertical standing seams, close enough to show faint mineral speckle, fine scuffs, and subtle cool mottling in the zinc surface.
Composition/framing: square edge-to-edge straight-on material tile, roughly three understated evenly spaced vertical seams extending through opposite edges; tile cleanly on all sides.
Lighting/mood: flat neutral overcast scan, natural variation only, no baked directional highlights, deep cast shadows or reflections. Neutral graphite with a subtle blue-gray cast.
Constraints: no objects, signage, border, horizon, drops, rust streaks, perspective or large patches.
```

## Snow particle atlas

```text
Use case: photorealistic-natural
Asset type: original 2×2 transparent snow-particle sprite atlas for a realistic 3D precipitation shader
Primary request: four photographic, irregular falling snow aggregates, one separate specimen per equal square quadrant, each centered with generous transparent margin. They should look like barely resolved clusters of icy powder and tiny crystals caught in air by a real camera, with uneven translucent contours and minute holes. Top left a compact dim rounded cottony clump, top right a thin irregular asymmetric small ice aggregate, bottom left a soft just-out-of-focus cluster, bottom right a wispy tiny pair of joined granular flakes.
Lighting/mood: diffuse cloudy neutral white with restrained blue-gray translucency and soft near-transparent edges, minimal contrast, camera exposure natural. Delicate particle textures, not icons.
Constraints: genuine transparent RGBA background; no checkerboard, no shadows on a backdrop, no quadrant lines, no text, no star-shaped six-point graphic flakes, no glow, no sparks, no symmetrical paper-cut silhouettes. Four sprites only. Keep all silhouettes within their own quadrant.
```

## Rain impact atlas

```text
Use case: photorealistic-natural
Asset type: original 2×2 transparent atlas for subtle rain impact splash particles in a physically lit outdoor game
Primary request: four separately isolated natural micro-splashes made by a single small rain drop on shallow water, four stages in equal square quadrants. Early short rising curved water crown at top left, tiny asymmetric spray crown at top right, sparse few transparent airborne drops over a collapsed crown at bottom left, and very faint irregular shallow low splash with two tiny airborne droplets bottom right.
Composition/framing: each splash is centered within its quadrant with generous true transparent margins. Side-on to gently above the horizontal, each spray has a narrow base and just a few hair-fine particles. Water is delicately translucent with tiny grayscale specular edges and muted cold white coloration.
Lighting/mood: realistic macro high-speed photography, soft overcast daylight. Avoid decorative imagery.
Constraints: actual RGBA transparency, clear background and no checkerboard, no puddle tile or ground, no text, no glowing ring, no large foamy wave, no frozen ice, no identical repeating icon shapes. Nothing touches another quadrant.
```

## Granular snow, bark, and alpine rock

```text
Create a new original photorealistic tileable PBR ALBEDO scan source of fresh natural alpine snow for a AAA real-time weather simulation. Square, maximum native resolution possible with very fine detail. Orthographic directly overhead, perfectly flat focus, edge-to-edge material with absolutely no background, border, objects, scenery, holes, bare ground, footprints, chunks, rocks, colored shadows or text. A roughly 1.6 meter square of untouched winter powder, slightly wind-packed with quiet asymmetric fine ripples, tiny crystalline granular variation, slight grain clustering, and very low contrast fluffy relief at several scales. Physically neutral warm-white / ice-white snow with no blue cast, diffuse overcast cross-polarized field-scan lighting, no specular glints, no directional shadows, no central subject, no repeating motifs. The variation should read as natural continuous snow, never as gray gravel, frost on metal, pebbles, clouds, ice or stippled paint. Seamless repeating texture where opposite edges naturally match. High photographic microdetail but low broad tonal contrast and no high-contrast edges. Deliver only the diffuse source image, no contact sheet.
```

```text
Use case: photorealistic-natural
Asset type: highest-resolution square albedo master for a 4096×4096 seamless PBR bark material used on a modeled alpine spruce trunk
Primary request: real close material scan of mature Norway spruce bark, gray-brown and subtle umber flaky plates, organically interrupted shallow fissures and a trace of muted lichen, fine natural fiber grain and small irregular scaly edges. Dense complexity at three scales. Tree age and species read from material even without geometry.
Composition/framing: orthographic surface scan, rectangular patterns extend vertically with some irregular transverse breaks; square tile edge-to-edge, repeat seamlessly top/bottom and left/right. Around 1.4 meters across for real scale.
Lighting/mood: de-lit neutral diffuse albedo capture, evenly exposed muted colors, no dark painted cracks, directional light, or cast shadows. Rich photographic detail, AAA game texture quality.
Constraints: no tree silhouette or branches, no sky, background, writing, frame, visible symmetry, stretched streaks, synthetic illustration, vignetting or large distinctive stamp. Output only the highest-resolution material image available.
```

```text
Use case: photorealistic-natural
Asset type: highest-resolution square albedo master for a 4096×4096 seamless PBR alpine rock material
Primary request: close de-lit material scan of exposed gray alpine limestone with irregular broad weathered bedding, sharp natural gray mineral flecks, faint cream veins and muted desaturated lichen in recesses. Real fractured rock with quiet natural color under cloud lighting. Fine grains and fine hairline seams maintain believable scales.
Composition/framing: directly facing orthographic flat surface sample, square and truly tileable on all four edges. Around 2.2 meters of surface across, preserve both fine grain and coherent bedding without a single dominant crack.
Lighting/mood: perfectly diffuse neutral material scan, minimal baked shading and no cast shadows or highlights. Highest photographic detail, cool-gray and gray-umber range.
Constraints: no cliff perspective, snow, objects, props, checker pattern, lettering, vignette, border or illustrative faceting. Output only the highest-resolution material image available.
```

## 2D and static cloud artwork

```text
Use case: photorealistic-natural
Asset type: original tileable monochrome opacity master for an animated 2D cloud layer in a realistic 3D sky
Primary request: straight-down plan view of a natural field of discrete, irregular low-to-mid-altitude cumulus clouds, represented strictly as a grayscale density field. Clouds have thick soft cores, irregular stacked lobes, fine broken and torn perimeters, variable size, and a few thin strands that connect neighboring forms. The pure-black openings are broad and organically shaped. Visual occupancy about 42%.
Composition/framing: square seamless map, top-down orthographic, edges tile in both axes, varied cloud clusters without a pattern. White and soft gray cloud density on a solid black background.
Lighting/mood: neutral gray data art, moderate contrast, render no directional light or cast shadow, since Godot supplies lighting dynamically.
Constraints: no blue or other colors, no horizon, no sun disk, no landscape, no checker, no hard icon contours, no uniform cotton balls, no repeating stripe, no text or border. High natural detail and distinct coherent masses.
```

```text
Use case: photorealistic-natural
Asset type: original square hemispherical cloud opacity master for a static cloud sky dome in a realistic 3D game
Primary request: upward-looking 180-degree fisheye opacity map of broken cumulus from ground level. The exact zenith is the image center, and the full circular horizon is at the edge of an inscribed circle. In grayscale on black, distinct natural cloud bodies occupy a roughly 45 percent sky fraction. Use curved coherent lobes and broken granular edges, some broad shaded central masses as high-density gray-white, and many smaller separated cloud banks receding toward the outer edge. Preserve real negative space through the center and between clouds.
Composition/framing: centered circular all-sky map, with no horizon line or ground. Outside the circular sky is solid pure black. Treat the square as a projection map, not a normal landscape frame. No image border or outline.
Lighting/mood: flat monochromatic density and diffuse internal variation suitable for dynamic light sampling. Real cloud morphology, highly detailed perimeter, neutral clean data.
Constraints: no baked sunlight or sun disk, no moon, no blue, no trees, no buildings, no text, no vignette, no repeated wispy radial stripes, no solid white sheets.
```

Static clouds read the derived texture's RGB relief channels at three directions spaced 120° apart and its separate alpha silhouette. [Relighting texture](../addons/dynamic_sky/rendering/cloud_modes/static_cloud_dome_lighting.png) · [Static lighting bake](../addons/dynamic_sky/rendering/cloud_modes/bake_static_cloud_lighting.py)
