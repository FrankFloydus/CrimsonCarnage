extends RefCounted
## Resolves receiver wind sources within their own World3D.


static func resolve(context: Node3D, explicit: Variant, cached: Variant) -> DynamicSky:
	var world := context.get_world_3d()
	if is_instance_valid(explicit):
		return explicit if _is_in_world(explicit, world) else null
	if is_instance_valid(cached) and _is_in_world(cached, world):
		return cached
	for candidate in context.get_tree().get_nodes_in_group(DynamicSky.GROUP):
		var sky := candidate as DynamicSky
		if _is_in_world(sky, world):
			return sky
	return null


static func _is_in_world(sky: DynamicSky, world: World3D) -> bool:
	return is_instance_valid(sky) and sky.is_inside_tree() and sky.get_world_3d() == world
