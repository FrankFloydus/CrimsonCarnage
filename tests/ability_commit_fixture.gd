extends RefCounted
## Independent payment and charge Resources for exact behavior assertions.


static func make_cost(pool: AmountDefinition.Pool, points: float) -> AbilityResourceCost:
	var cost := AbilityResourceCost.new()
	cost.pool = pool
	cost.amount = AmountDefinition.fixed(points)
	return cost


static func make_cooldown(seconds: float, group: StringName = &"") -> AbilityChargeDefinition:
	var profile := AbilityChargeDefinition.new()
	profile.recharge_seconds = seconds
	profile.shared_group = group
	return profile
