class_name WorldVisuals
extends RefCounted
## Builds all static visuals for a generated Terrain.

static var noise_tex: NoiseTexture2D


static func get_noise_tex() -> NoiseTexture2D:
	if noise_tex == null:
		noise_tex = NoiseTexture2D.new()
		noise_tex.width = 256
		noise_tex.height = 256
		noise_tex.seamless = true
		var n := FastNoiseLite.new()
		n.frequency = 0.02
		n.fractal_octaves = 4
		noise_tex.noise = n
		noise_tex.generate_mipmaps = true
	return noise_tex


static func build(root: Node3D, t: Terrain, quality: int) -> void:
	_build_terrain(root, t)
	_build_water(root)
	_build_props(root, t, quality)


static func _terrain_color(t: Terrain, x: float, z: float, y: float, n: Vector3) -> Color:
	var soil := Color(0.62, 0.33, 0.2)
	var dry := Color(0.72, 0.6, 0.36)
	var litter := Color(0.44, 0.33, 0.23)
	var green := Color(0.42, 0.45, 0.24)
	var sand := Color(0.8, 0.69, 0.52)
	var mud := Color(0.3, 0.25, 0.19)
	var rock := Color(0.6, 0.36, 0.25)
	var col := soil
	var g := t.grassiness(x, z)
	col = col.lerp(dry, g * 0.75)
	col = col.lerp(litter, t.woodland(x, z) * 0.7)
	var m := t.moisture(x, z)
	col = col.lerp(green, m * m * 0.6)
	if y < 0.9 and y > -0.3:
		col = col.lerp(sand, smoothstep(0.9, 0.2, y) * 0.85)
	if y <= -0.3:
		col = mud.lerp(Color(0.2, 0.17, 0.13), clampf(-y / 2.0, 0.0, 1.0))
	var steep := smoothstep(0.85, 0.6, n.y)
	var rk := maxf(steep, (1.0 - smoothstep(18.0, 32.0, Vector2(x, z).distance_to(Terrain.OUTCROP_POS))) * 0.7)
	if y > 7.0:
		rk = maxf(rk, smoothstep(7.0, 10.0, y))
	var strata := 0.5 + 0.5 * sin(y * 2.3 + t.n_mid.get_noise_2d(x, z) * 2.0)
	col = col.lerp(rock.lerp(Color(0.72, 0.45, 0.3), strata * 0.5), rk)
	var nd := Vector2(x, z).distance_to(Terrain.NEST_POS)
	if nd < 16.0:
		col = col.lerp(Color(0.7, 0.45, 0.3), smoothstep(16.0, 6.0, nd) * 0.5)
	return col


static func _build_terrain(root: Node3D, t: Terrain) -> void:
	# Full heightmap resolution so the visible ground is exactly the ground
	# creatures walk on. Colors are computed on a 2 m grid and interpolated.
	var gn := Terrain.N
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/terrain.gdshader")
	mat.set_shader_parameter("noise_tex", get_noise_tex())
	mat.set_shader_parameter("ground_tex", _tex("ground_detail"))
	mat.set_shader_parameter("ground_nrm", _tex("ground_normal"))
	mat.set_shader_parameter("rock_tex", _tex("rock_detail"))
	mat.set_shader_parameter("rock_nrm", _tex("rock_normal"))
	var cn := (gn - 1) / 2 + 1
	var ccol := PackedColorArray()
	ccol.resize(cn * cn)
	for j in cn:
		for i in cn:
			var x := -Terrain.HALF + i * 2.0 * Terrain.CELL
			var z := -Terrain.HALF + j * 2.0 * Terrain.CELL
			var y := t.hmap(x, z)
			var n := Vector3(t.hmap(x - 1.0, z) - t.hmap(x + 1.0, z), 2.0, t.hmap(x, z - 1.0) - t.hmap(x, z + 1.0)).normalized()
			ccol[j * cn + i] = _terrain_color(t, x, z, y, n)
	var pos := PackedVector3Array()
	var nor := PackedVector3Array()
	var col := PackedColorArray()
	pos.resize(gn * gn)
	nor.resize(gn * gn)
	col.resize(gn * gn)
	for j in gn:
		for i in gn:
			var k := j * gn + i
			var x := -Terrain.HALF + i * Terrain.CELL
			var z := -Terrain.HALF + j * Terrain.CELL
			pos[k] = Vector3(x, t.h[k], z)
			var hl := t.h[k - 1] if i > 0 else t.h[k]
			var hr := t.h[k + 1] if i < gn - 1 else t.h[k]
			var hd := t.h[k - gn] if j > 0 else t.h[k]
			var hu := t.h[k + gn] if j < gn - 1 else t.h[k]
			nor[k] = Vector3(hl - hr, 2.0 * Terrain.CELL, hd - hu).normalized()
			var ci := i / 2
			var cj := j / 2
			var ci2 := mini(ci + (i % 2), cn - 1)
			var cj2 := mini(cj + (j % 2), cn - 1)
			var c00 := ccol[cj * cn + ci]
			var c11 := ccol[cj2 * cn + ci2]
			var c10 := ccol[cj * cn + ci2]
			var c01 := ccol[cj2 * cn + ci]
			col[k] = (c00 + c11 + c10 + c01) * 0.25
	var chunk := 48
	var cells := gn - 1
	var chunks := int(ceil(float(cells) / chunk))
	for cj in chunks:
		for ci in chunks:
			var i0 := ci * chunk
			var j0 := cj * chunk
			var i1 := mini(i0 + chunk, cells)
			var j1 := mini(j0 + chunk, cells)
			var v := PackedVector3Array()
			var nn := PackedVector3Array()
			var cc := PackedColorArray()
			var idx := PackedInt32Array()
			var w := i1 - i0 + 1
			for j in range(j0, j1 + 1):
				for i in range(i0, i1 + 1):
					var k2 := j * gn + i
					v.append(pos[k2])
					nn.append(nor[k2])
					cc.append(col[k2])
			for j in range(j1 - j0):
				for i in range(i1 - i0):
					var a := j * w + i
					var b := a + 1
					var c2 := a + w
					var d := c2 + 1
					idx.append_array([a, b, d, a, d, c2])
			var arr := []
			arr.resize(Mesh.ARRAY_MAX)
			arr[Mesh.ARRAY_VERTEX] = v
			arr[Mesh.ARRAY_NORMAL] = nn
			arr[Mesh.ARRAY_COLOR] = cc
			arr[Mesh.ARRAY_INDEX] = idx
			var m := ArrayMesh.new()
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			var mi := MeshInstance3D.new()
			mi.mesh = m
			mi.material_override = mat
			root.add_child(mi)
	# distant ring of flat country beyond the escarpment so the horizon never shows the void
	var mb := MeshBuilder.new()
	var r0 := Terrain.HALF - 2.0
	var r1 := 1500.0
	var ry := 16.0
	var sc := Color(0.6, 0.4, 0.27)
	var corners := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	for k in 4:
		var a0: Vector2 = corners[k]
		var a1: Vector2 = corners[(k + 1) % 4]
		var i0 := Vector3(a0.x * r0, ry, a0.y * r0)
		var i1 := Vector3(a1.x * r0, ry, a1.y * r0)
		var o0 := Vector3(a0.x * r1, ry, a0.y * r1)
		var o1 := Vector3(a1.x * r1, ry, a1.y * r1)
		mb.tri(i0, o1, o0, sc, sc, sc, Vector3.UP, Vector3.UP, Vector3.UP)
		mb.tri(i0, i1, o1, sc, sc, sc, Vector3.UP, Vector3.UP, Vector3.UP)
	var skirt := MeshInstance3D.new()
	skirt.mesh = mb.commit()
	var sm := StandardMaterial3D.new()
	sm.vertex_color_use_as_albedo = true
	sm.vertex_color_is_srgb = true
	sm.roughness = 1.0
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	skirt.material_override = sm
	skirt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(skirt)


static func _build_water(root: Node3D) -> void:
	var water := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(Terrain.HALF * 2.0, Terrain.HALF * 2.0)
	pm.subdivide_width = 120
	pm.subdivide_depth = 120
	water.mesh = pm
	water.position = Vector3(0, Terrain.WATER_Y, 0)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/water.gdshader")
	mat.set_shader_parameter("noise_tex", get_noise_tex())
	water.material_override = mat
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(water)


static func _mm(root: Node3D, mesh: Mesh, xforms: Array, mat: Material, shadows := true, vis_end := 0.0, colors: Array = []) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not colors.is_empty()
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		if mm.use_colors:
			mm.set_instance_color(i, colors[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	if mat != null:
		mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if vis_end > 0.0:
		mmi.visibility_range_end = vis_end
		mmi.visibility_range_end_margin = 8.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	root.add_child(mmi)


static func _tex(name: String) -> Texture2D:
	return load("res://assets/textures/%s.png" % name)


static func _leaf_mat(tex: String, sway: float, cut := 0.45) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://assets/shaders/leaves.gdshader")
	m.set_shader_parameter("leaf_tex", _tex(tex))
	m.set_shader_parameter("sway", sway)
	m.set_shader_parameter("alpha_cut", cut)
	return m


static func _bark_mat(tex: String, axis_z := false) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://assets/shaders/bark.gdshader")
	m.set_shader_parameter("bark_tex", _tex(tex))
	m.set_shader_parameter("bark_nrm", _tex(tex + "_normal"))
	m.set_shader_parameter("axis_z", 1.0 if axis_z else 0.0)
	m.set_shader_parameter("scale", Vector2(1.0, 2.0) if not axis_z else Vector2(1.0, 1.0))
	return m


static func _rock_mat(mix_amt := 1.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://assets/shaders/rock.gdshader")
	m.set_shader_parameter("rock_tex", _tex("rock_detail"))
	m.set_shader_parameter("rock_nrm", _tex("rock_normal"))
	m.set_shader_parameter("tex_mix", mix_amt)
	return m


static func _build_props(root: Node3D, t: Terrain, quality: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 991
	var foliage := ShaderMaterial.new()
	foliage.shader = load("res://assets/shaders/foliage.gdshader")
	foliage.set_shader_parameter("sway", 0.05)
	var grass_mat := ShaderMaterial.new()
	grass_mat.shader = foliage.shader
	grass_mat.set_shader_parameter("sway", 0.09)
	var plain := StandardMaterial3D.new()
	plain.vertex_color_use_as_albedo = true
	plain.vertex_color_is_srgb = true
	plain.roughness = 0.92
	# ---- trees: several variants per kind
	var tree_variants := [[], []]
	var leaf_m := _leaf_mat("leaves_euc", 0.04)
	var bark_ms := [_bark_mat("bark_stringy"), _bark_mat("bark_gum")]
	for kind in 2:
		for v in 4:
			var tm := VegCards.tree(rng, kind == 1)
			tm.surface_set_material(0, bark_ms[kind])
			tm.surface_set_material(1, leaf_m)
			tree_variants[kind].append(tm)
	var tree_x := {}
	for tr in t.trees:
		var v2 := rng.randi_range(0, 3)
		var key := str(tr.kind) + "_" + str(v2)
		if not tree_x.has(key):
			tree_x[key] = []
		var s: float = tr.height
		var xf := Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s * 0.9, s, s * 0.9)), Vector3(tr.p.x, tr.y - 0.1, tr.p.y))
		tree_x[key].append(xf)
	for key in tree_x.keys():
		var parts: PackedStringArray = key.split("_")
		_mm(root, tree_variants[int(parts[0])][int(parts[1])], tree_x[key], null, true)
	# ---- bushes & spinifex
	var shrub_meshes := [VegCards.shrub(rng, false), VegCards.shrub(rng, false), VegCards.shrub(rng, true)]
	var bush_m := _leaf_mat("leaves_bush", 0.05, 0.5)
	var spin_meshes := [Vegetation.spinifex(rng), Vegetation.spinifex(rng)]
	var bx := [[], [], []]
	var sx := [[], []]
	for b in t.bushes:
		var y := t.hmap(b.p.x, b.p.y)
		if b.kind == 0:
			var s2: float = b.r
			bx[rng.randi_range(0, 2)].append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s2, s2 * rng.randf_range(0.7, 1.1), s2)), Vector3(b.p.x, y - 0.05, b.p.y)))
		else:
			var s3: float = b.r * 1.2
			sx[rng.randi_range(0, 1)].append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s3, s3 * 0.8, s3)), Vector3(b.p.x, y - 0.03, b.p.y)))
	for i in 3:
		_mm(root, shrub_meshes[i], bx[i], bush_m, true, 160.0)
	for i in 2:
		_mm(root, spin_meshes[i], sx[i], grass_mat, true, 120.0)
	# ---- boulders and slabs
	var rock_meshes := []
	for i in 4:
		rock_meshes.append(VegCards.rock(rng, Color(0.7, 0.45, 0.32).lerp(Color(0.6, 0.5, 0.44), rng.randf() * 0.5)))
	var rock_m := _rock_mat()
	var rx := [[], [], [], []]
	for b in t.boulders:
		var r: float = b.r
		var hgt: float = b.hgt
		rx[rng.randi_range(0, 3)].append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(r, hgt, r * rng.randf_range(0.8, 1.2))), Vector3(b.p.x, b.y + hgt * 0.25, b.p.y)))
	for i in 4:
		_mm(root, rock_meshes[i], rx[i], rock_m, true)
	var slab_mesh := Vegetation.slab_rock(Color(0.68, 0.42, 0.29))
	var slx := []
	for s in t.slabs:
		var bas := Basis(Vector3.UP, -s.yaw).scaled(Vector3(s.rx, s.ry, s.rz))
		slx.append(Transform3D(bas, Vector3(s.p.x, s.base, s.p.y)))
	_mm(root, slab_mesh, slx, rock_m, true)
	# ---- logs
	var log_mesh := Vegetation.log_mesh(rng)
	var lx := []
	for l in t.logs:
		var a: Vector2 = l.a
		var b2: Vector2 = l.b
		var mid := (a + b2) * 0.5
		var dir := (b2 - a)
		var ln := dir.length()
		var yaw := atan2(dir.x, dir.y)
		var bas2 := Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(l.r, l.r, ln))
		lx.append(Transform3D(bas2, Vector3(mid.x, t.hmap(mid.x, mid.y) + l.r * 0.75, mid.y)))
	_mm(root, log_mesh, lx, _bark_mat("bark_stringy", true), true)
	# ---- termite mounds
	var tm := Vegetation.termite_mound(rng)
	var tmx := []
	for m in t.mounds:
		tmx.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(m.r * 1.6, m.hgt, m.r * 1.6)), Vector3(m.p.x, m.y - 0.1, m.p.y)))
	_mm(root, tm, tmx, _rock_mat(0.7), true)
	# ---- turkey mounds
	var tkm := Vegetation.turkey_mound(rng)
	var tkx := []
	for m2 in t.turkey_mounds:
		var y2 := t.hmap(m2.p.x, m2.p.y)
		tkx.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(m2.r * 1.4, 1.0, m2.r * 1.4)), Vector3(m2.p.x, y2, m2.p.y)))
	_mm(root, tkm, tkx, _rock_mat(0.35), true)
	# ---- reeds
	var reed_meshes := [Vegetation.reed(rng), Vegetation.reed(rng)]
	var rdx := [[], []]
	for r2 in t.reeds:
		var y3 := t.hmap(r2.p.x, r2.p.y)
		var s4 := rng.randf_range(0.7, 1.2)
		rdx[rng.randi_range(0, 1)].append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s4, s4, s4)), Vector3(r2.p.x, y3 - 0.05, r2.p.y)))
	for i in 2:
		_mm(root, reed_meshes[i], rdx[i], grass_mat, false, 110.0)
	# ---- grass tufts & pebbles, chunked for distance culling
	var dens: float = [0.18, 0.32, 0.5][clampi(quality, 0, 2)]
	var tufts := [VegCards.grass(rng, false), VegCards.grass(rng, false), VegCards.grass(rng, true)]
	var grass_m := _leaf_mat("grass_card", 0.09, 0.5)
	var peb := Vegetation.pebbles(rng)
	var csz := 40.0
	var nchunk := int(ceil(Terrain.PLAY_HALF * 2.0 / csz))
	for cj in nchunk:
		for ci in nchunk:
			var gx := [[], [], []]
			var px := []
			var ox := -Terrain.PLAY_HALF + ci * csz
			var oz := -Terrain.PLAY_HALF + cj * csz
			var count := int(csz * csz * dens)
			for k in count:
				var x := ox + rng.randf() * csz
				var z := oz + rng.randf() * csz
				var g := t.grassiness(x, z)
				if rng.randf() > g:
					if rng.randf() < 0.04:
						var y4 := t.height(x, z)
						if y4 > 0.1:
							px.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(x, y4, z)))
					continue
				var y5 := t.height(x, z)
				if y5 < 0.12:
					continue
				var s5 := rng.randf_range(0.6, 1.3) * (0.7 + g * 0.5)
				var green := t.moisture(x, z) > 0.5
				var vi := 2 if green else rng.randi_range(0, 1)
				gx[vi].append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s5, s5 * rng.randf_range(0.8, 1.3), s5)), Vector3(x, y5 - 0.02, z)))
			var vend: float = [45.0, 60.0, 80.0][clampi(quality, 0, 2)]
			for i in 3:
				_mm_chunk(root, tufts[i], gx[i], grass_m, vend, Vector3(ox + csz * 0.5, 0, oz + csz * 0.5))
			_mm_chunk(root, peb, px, plain, 40.0, Vector3(ox + csz * 0.5, 0, oz + csz * 0.5))


static func _mm_chunk(root: Node3D, mesh: Mesh, xforms: Array, mat: Material, vis_end: float, center: Vector3) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		var xf: Transform3D = xforms[i]
		xf.origin -= center
		mm.set_instance_transform(i, xf)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.position = center
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = vis_end + 28.0
	mmi.visibility_range_end_margin = 10.0
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	root.add_child(mmi)
