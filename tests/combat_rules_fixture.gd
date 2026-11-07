extends RefCounted
## Deterministic inputs for exact combat math assertions in isolated headless suites.

const VALUES: Dictionary = {
	"max_level": 60,
	"creation_points": 0,
	"points_per_level": 2,
	"movement_speed_min_percent": -100.0,
	"movement_speed_max_percent": 25.0,
	"action_speed_max_percent": 100.0,
	"critical_chance_min_percent": 0.0,
	"critical_chance_max_percent": 100.0,
	"base_critical_multiplier": 1.5,
	"armor_rating_at_cap": 1000.0,
	"armor_max_reduction": 0.75,
	"armor_penetration_min_percent": 0.0,
	"armor_penetration_max_percent": 100.0,
	"resistance_min_percent": -100.0,
	"resistance_max_percent": 80.0,
	"strength_physical_power_per_point": 2.0,
	"dexterity_physical_power_per_point": 2.0,
	"governing_accuracy_per_point": 1.0,
	"minimum_capacity": 1.0,
	"accuracy_base_chance_by_gap": [0.8, 0.75, 0.68, 0.6, 0.5, 0.4, 0.24, 0.18, 0.14, 0.11, 0.08],
	"accuracy_max_chance_by_gap": [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.5, 0.35, 0.25, 0.16, 0.1],
	"accuracy_baseline_rating": 10.0,
	"accuracy_curve_max_gap": 10,
	"accuracy_rating_scale_base": 20.0,
	"accuracy_rating_scale_per_level": 2.0,
	"accuracy_rating_scale_per_gap": 10.0,
	"accuracy_lower_level_bonus": 0.04,
	"accuracy_higher_level_decay": 0.75,
}


## Each suite runs in its own process. Give the production reader a test-owned copy.
static func install() -> void:
	CombatRules._values = VALUES.duplicate(true)
	CombatRules._loaded = true
