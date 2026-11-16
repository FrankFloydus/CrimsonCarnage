extends SceneTree
## Rebuilds the saved demo collision shapes after importing authored terrain or rock geometry.


func _initialize() -> void:
	for stem: String in ["lookout_terrain", "details/ridge_outcrop", "details/ridge_outcrop_small"]:
		var base_path := "res://addons/dynamic_sky/demo/landscape/" + stem
		var mesh := load(base_path + ".obj") as Mesh
		assert(mesh != null, "Import the authored OBJ before rebuilding collision: " + base_path)
		var shape := mesh.create_trimesh_shape()
		assert(shape != null)
		var error := ResourceSaver.save(shape, base_path + "_collision.res")
		assert(error == OK, "Could not save collision: " + base_path)
		print("COLLISION_SAVED ", base_path, " triangles=", shape.get_faces().size() / 3)
	quit()
