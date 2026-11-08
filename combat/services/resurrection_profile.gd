class_name ResurrectionProfile
extends Resource
## Conditions and restore amounts for a resurrection entitlement.

## Policy schema revision for the world adapter's diagnostics.
@export_range(1, 2147483647, 1) var version: int = 1
## Seconds the entitlement remains valid. Zero has no time limit.
@export_range(0.0, 3600.0, 0.1, "or_greater") var duration: float = 0.0
## Shared encounter budget identifier. Empty uses no shared budget.
@export var budget_id: StringName
## Whether the target must explicitly accept before the restore adapter can run.
@export var requires_acceptance: bool = true
## Whether declining an offered resurrection removes this entitlement.
@export var consume_on_decline: bool = false
## Whether a real death of the source invalidates the entitlement.
@export var cancel_on_source_death: bool = false
## Whether an entitlement can be granted after the recipient is already dead.
@export var allow_grant_to_dead: bool = false
## Fraction of effective maximum Health requested from the resurrection adapter.
@export_range(0.01, 1.0, 0.01) var health_fraction: float = 0.3
## Fraction of effective maximum Stamina requested from the resurrection adapter.
@export_range(0.0, 1.0, 0.01) var stamina_fraction: float = 0.0
## Fraction of effective maximum Mana requested from the resurrection adapter.
@export_range(0.0, 1.0, 0.01) var mana_fraction: float = 0.0
