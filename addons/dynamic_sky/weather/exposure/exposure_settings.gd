class_name DynamicSkyExposureSettings
extends Resource
## Local observer response to volumetric cloud height and authored water surfaces.

## Enables the local exposure rules on the component using this resource.
@export var enabled: bool = true

@export_group("Above Volumetric Clouds")
## Suppresses local weather within and above the volumetric cloud layer.
@export var above_clouds_enabled: bool = true
## Fraction of layer thickness at which above-cloud suppression begins.
@export_range(0.0, 1.0, 0.01) var suppression_start: float = 0.10
## Fraction of layer thickness at which the above-cloud multipliers apply fully.
@export_range(0.0, 1.0, 0.01) var suppression_end: float = 0.65
## Rain intensity remaining above the cloud layer.
@export_range(0.0, 1.0, 0.01) var rain_multiplier: float = 0.0
## Snow intensity remaining above the cloud layer.
@export_range(0.0, 1.0, 0.01) var snow_multiplier: float = 0.0
## Airborne dust remaining above the cloud layer.
@export_range(0.0, 1.0, 0.01) var dust_multiplier: float = 0.0
## Distance fog remaining above the cloud layer.
@export_range(0.0, 1.0, 0.01) var fog_multiplier: float = 0.0
## Visible and obscured thunderstorm event rates remaining above the cloud layer.
@export_range(0.0, 1.0, 0.01) var thunder_multiplier: float = 0.0
## Local observer wind remaining above the cloud layer.
@export_range(0.0, 1.0, 0.01) var wind_multiplier: float = 0.5

@export_group("Water Surfaces")
## Enables a constant global surface height. Higher local water regions take precedence.
@export var global_water_enabled: bool = false
## Absolute world Y of the global water plane, in meters.
@export_range(-1000000.0, 1000000.0, 0.1, "suffix:m") var global_water_level: float = 0.0
## Includes enabled Box and Sphere water regions in this World3D.
@export var local_water_regions_enabled: bool = true
## Clears lens droplets, frost, and heat while the observer is submerged.
@export var suppress_screen_underwater: bool = true
## Requests the muffled ambience route while submerged.
@export var force_underwater_audio_occlusion: bool = true
## Wets the lens when the camera emerges after the startup delay.
@export var wet_screen_on_emerge: bool = true
## Minimum runtime before an emerging observer wets the lens. This excludes startup teleports.
@export_range(0.0, 30.0, 0.1, "suffix:s") var emerging_runtime_delay_seconds: float = 1.0
