@tool
class_name CombatCopyPolicy
extends Resource
## Shared scaling for copied damage or healing amounts.

## Percentage of the selected source-stage amount used for the new payload. 40 means 40%.
@export_range(0.0, 100.0, 0.1, "or_greater", "suffix:%") var effectiveness_percent: float = 100.0


func get_validation_error() -> StringName:
	if not is_finite(effectiveness_percent) or effectiveness_percent < 0.0:
		return &"invalid_copy_policy"
	return &""


func scale_amount(source_amount: float) -> float:
	return source_amount * effectiveness_percent / 100.0
