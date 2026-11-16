class_name DynamicSkyNightStormSettings
extends Resource
## Optional nighttime Storm lighting and observer exposure. Assign through Exposure Settings.

## Practical exposure used only when the active camera and World3D have no authored camera attributes.
@export var camera_attributes: CameraAttributesPractical

## Multiplies the Moon directional light in full nighttime Storm. The visible Moon retains its authored brightness.
@export_range(0.0, 1.0, 0.01) var moon_irradiance: float = 0.13
## Multiplies sky cubemap irradiance in full nighttime Storm. The visible sky uses its normal lighting.
@export_range(0.0, 1.0, 0.01) var sky_irradiance: float = 0.13

## Strength of the shadow tone curve while the fallback camera exposure is active. An authored Environment grade takes precedence.
@export_range(0.0, 1.0, 0.01) var shadow_grade_strength: float = 1.0
## Display-space luma at which the shadow grade reaches identity and keeps highlight levels unchanged.
@export_range(0.04, 0.7, 0.005) var shadow_toe_end: float = 0.33

## Seconds to pause only bright-scene adaptation after a full strike. Zero keeps the authored rates throughout.
@export_range(0.0, 2.0, 0.05, "suffix:s") var flash_hold_seconds: float = 0.0
