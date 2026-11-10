class_name BloodFloorSplatter
extends Resource
## Pairs a world splatter silhouette with its wet surface maps.

## Color density and opacity of the deposited blood.
@export var albedo: Texture2D
## Matched occlusion, roughness, and metallic map. The green channel controls wetness.
@export var orm: Texture2D
## Subtle liquid relief that breaks up reflections across the deposit.
@export var normal: Texture2D
## Align this variant's hanging runs mostly downhill on wall surfaces.
@export var wall_drips := false
