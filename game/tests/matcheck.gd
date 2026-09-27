extends SceneTree
func _init():
	for sp in ["turkey", "crow", "dingo", "eagle"]:
		var s: PackedScene = load("res://assets/creatures/%s.glb" % sp)
		var n = s.instantiate()
		for m in n.find_children("*", "MeshInstance3D", true, false):
			var mat = m.mesh.surface_get_material(0)
			if mat is StandardMaterial3D:
				print(sp, " rough=", mat.roughness, " rtex=", mat.roughness_texture != null, " ch=", mat.roughness_texture_channel, " metal=", mat.metallic, " mtex=", mat.metallic_texture != null, " spec=", mat.metallic_specular, " normal=", mat.normal_enabled, " nscale=", mat.normal_scale, " cull=", mat.cull_mode)
		n.free()
	quit()
