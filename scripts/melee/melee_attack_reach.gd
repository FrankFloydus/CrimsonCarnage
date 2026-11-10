@tool
class_name MeleeAttackReach
extends Resource
## Adjusts the base weapon sweep for one attack.

const VERMINTIDE_REACH_SCALE := 1.10

## Multiplies the weapon's base sweep length after the Vermintide-style 1.10 scale.
@export_range(0.0, 4.0, 0.01, "or_greater", "suffix:×") var reach_multiplier: float = 1.0
## Meters added to the scaled box length. Negative values shorten the box. A nonpositive final length disables contact.
@export_range(-5.0, 5.0, 0.01, "or_less", "or_greater", "suffix:m") var flat_bonus: float = 0.0
## Meters to shift the whole box along the blade. Positive moves toward the tip, and negative moves toward the grip.
@export_range(-5.0, 5.0, 0.01, "or_less", "or_greater", "suffix:m") var blade_offset: float = 0.0


## Returns the adjusted full length in meters for a valid weapon base span.
func resolve_length(base_length: float) -> float:
	return maxf(0.0, base_length * VERMINTIDE_REACH_SCALE * reach_multiplier + flat_bonus)
