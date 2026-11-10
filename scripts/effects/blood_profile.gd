class_name BloodProfile
extends Resource
## Preset for the airborne blood, world deposits, and skin stains caused by hitting an enemy.

## Texture library, deposit palette, and appearance variation shared by world and skin marks.
@export var splatter_style: BloodSplatterStyle

@export_group("Airborne Burst")
## BloodBurst3D scene that plays at the wound. Leave empty to skip the airborne effect.
@export var burst_scene: PackedScene
## Multiplies the airborne draw material's color. White keeps the authored colors.
@export var burst_tint := Color.WHITE
## Multiplier for the number of torn liquid patches in the burst.
@export_range(0.1, 4.0, 0.05) var liquid_amount_scale := 1.0
## Multiplier for the number of fine spray droplets in the burst.
@export_range(0.1, 4.0, 0.05) var droplet_amount_scale := 1.0
## Multiplier for the number of near-hit mist particles.
@export_range(0.1, 4.0, 0.05) var mist_amount_scale := 1.0
## Multiplier for the initial speeds of the visible particles.
@export_range(0.1, 3.0, 0.05) var burst_speed_scale := 1.0
## Multiplier for how widely the visible particles fan out around the hit.
@export_range(0.1, 3.0, 0.05) var burst_spread_scale := 1.0
## Multiplier for the liquid patches' stretch time, which controls streak length.
@export_range(0.1, 3.0, 0.05) var liquid_trail_scale := 1.0

@export_group("World Splatter")
## Base wall decal dimensions in meters. X and Z are the footprint and Y is projection depth.
@export var wall_size := Vector3(1.8, 0.22, 2.15)
## Base floor width and length in meters, before style variation and glancing stretch.
@export var floor_footprint := Vector2(1.95, 2.15)
## Floor projection depth in meters for uneven surfaces and shallow steps.
@export_range(0.035, 0.4, 0.005, "suffix:m") var floor_projection_depth := 0.16
## Maximum length multiplier on a floor impact that approaches parallel to the surface.
@export_range(1.0, 2.0, 0.01) var floor_grazing_stretch := 1.24
## Maximum wall center offset as a fraction of the decal's length. Zero centers it on impact.
@export_range(0.0, 0.25, 0.01) var wall_center_shift := 0.08
## Initial speed of the invisible droplet that places the main world decal.
@export_range(0.1, 20.0, 0.1, "suffix:m/s") var droplet_speed := 5.0
## Maximum angle in degrees between the swing and the main world droplet.
@export_range(0.0, 45.0, 0.5, "suffix:°") var character_spray_spread := 22.0
## Downward speed of the floor fallout. Zero disables the extra droplet.
@export_range(0.0, 15.0, 0.1, "suffix:m/s") var fallout_speed := 5.8
## Fraction of the normal floor footprint used by the near-target fallout.
@export_range(0.1, 1.0, 0.01) var fallout_footprint_scale := 0.76

@export_group("Body Stains")
## Base width and length in meters before style variation, in bind space for skinned meshes.
@export var stain_size := Vector2(0.5, 0.58)
## Maximum distance in meters from the hit plane that can receive a stain.
@export_range(0.001, 0.3, 0.001, "suffix:m") var stain_depth := 0.08
## Opacity multiplier for new body stains.
@export_range(0.0, 1.0, 0.01) var stain_strength := 0.95
## Number of body marks the target retains before replacing its oldest mark.
@export_range(1, 12, 1) var stain_limit := 12

@export_group("Debug")
## Draws the collision spheres of this profile's live world and fallout droplets during play.
@export var show_droplet_wires := false
