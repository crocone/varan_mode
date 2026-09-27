extends SceneTree
func _init():
	var m: Array = ReptileHead.get_meshes("monitor", Color(0.13,0.12,0.1), Color(0.84,0.74,0.46), Color(0.62,0.56,0.4))
	for mesh in m:
		var a = mesh.surface_get_arrays(0)
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
		var c: PackedColorArray = a[Mesh.ARRAY_COLOR]
		var bad := 0
		var maxc := 0.0
		for i in v.size():
			if not n[i].is_finite() or not v[i].is_finite() or n[i].length() < 0.5: bad += 1
			maxc = max(maxc, max(c[i].r, max(c[i].g, c[i].b)))
		print("verts ", v.size(), " bad ", bad, " maxcol ", maxc, " aabb ", mesh.get_aabb())
	quit()
