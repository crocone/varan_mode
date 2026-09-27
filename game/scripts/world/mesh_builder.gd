class_name MeshBuilder
extends RefCounted
## Small procedural mesh toolkit. Collects triangles with normals and vertex
## colors, then commits to an ArrayMesh. All primitives accept a Transform3D.

var verts := PackedVector3Array()
var norms := PackedVector3Array()
var cols := PackedColorArray()
var uvs := PackedVector2Array()   # uv.x often used as "sway weight" by shaders
var use_uv := false
var uv2s := PackedVector2Array()  # uv2.x = sway weight for textured cards / bark
var use_uv2 := false
var sway_w := 0.0                 # uv2.x written by tri() when no explicit uv2


func tri(a: Vector3, b: Vector3, c: Vector3, ca: Color, cb: Color, cc: Color, na := Vector3.ZERO, nb := Vector3.ZERO, nc := Vector3.ZERO, ua := Vector2.ZERO, ub := Vector2.ZERO, uc := Vector2.ZERO) -> void:
	if na == Vector3.ZERO:
		var n := (b - a).cross(c - a).normalized()
		na = n
		nb = n
		nc = n
	# Callers pass counter-clockwise (outward normal = (b-a)x(c-a)); Godot's
	# front faces are clockwise, so emit reversed.
	verts.append(a); verts.append(c); verts.append(b)
	norms.append(na); norms.append(nc); norms.append(nb)
	cols.append(ca); cols.append(cc); cols.append(cb)
	uvs.append(ua); uvs.append(uc); uvs.append(ub)
	uv2s.append(Vector2(sway_w, 0)); uv2s.append(Vector2(sway_w, 0)); uv2s.append(Vector2(sway_w, 0))


## Ellipsoid (smooth). color_fn optional Callable(local_unit_dir:Vector3)->Color.
func ellipsoid(xf: Transform3D, radii: Vector3, color: Color, seg := 10, rings := 7, color_fn = null, jitter := 0.0, rng: RandomNumberGenerator = null, flat := false) -> void:
	var grid: Array = []
	for r in rings + 1:
		var row: Array = []
		var v := float(r) / rings
		var phi := PI * v
		for s in seg + 1:
			var u := float(s) / seg
			var th := TAU * u
			var d := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
			var j := 1.0
			if jitter > 0.0 and rng != null and r > 0 and r < rings and s < seg:
				j = 1.0 + rng.randf_range(-jitter, jitter)
			row.append(d * j)
		if jitter > 0.0:
			row[seg] = row[0]
		grid.append(row)
	for r in rings:
		for s in seg:
			var d00: Vector3 = grid[r][s]
			var d01: Vector3 = grid[r][s + 1]
			var d10: Vector3 = grid[r + 1][s]
			var d11: Vector3 = grid[r + 1][s + 1]
			var p00 := xf * (d00 * radii)
			var p01 := xf * (d01 * radii)
			var p10 := xf * (d10 * radii)
			var p11 := xf * (d11 * radii)
			var c00: Color = color if color_fn == null else color_fn.call(d00)
			var c01: Color = color if color_fn == null else color_fn.call(d01)
			var c10: Color = color if color_fn == null else color_fn.call(d10)
			var c11: Color = color if color_fn == null else color_fn.call(d11)
			if flat:
				if r > 0:
					tri(p00, p01, p11, c00, c01, c11)
				if r < rings - 1:
					tri(p00, p11, p10, c00, c11, c10)
			else:
				var n00 := (xf.basis * (d00 / (radii * radii))).normalized()
				var n01 := (xf.basis * (d01 / (radii * radii))).normalized()
				var n10 := (xf.basis * (d10 / (radii * radii))).normalized()
				var n11 := (xf.basis * (d11 / (radii * radii))).normalized()
				if r > 0:
					tri(p00, p01, p11, c00, c01, c11, n00, n01, n11)
				if r < rings - 1:
					tri(p00, p11, p10, c00, c11, c10, n00, n11, n10)


## Tapered tube between two points (open ends unless caps).
func tube(a: Vector3, b: Vector3, ra: float, rb: float, ca: Color, cb: Color, seg := 7, cap := true, ua := 0.0, ub := 0.0) -> void:
	var axis := b - a
	if axis.length() < 0.0001:
		return
	var dir := axis.normalized()
	var ref := Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT
	var sx := dir.cross(ref).normalized()
	var sz := dir.cross(sx).normalized()
	var slope := (ra - rb) / axis.length()
	for s in seg:
		var t0 := TAU * s / seg
		var t1 := TAU * (s + 1) / seg
		var o0 := sx * cos(t0) + sz * sin(t0)
		var o1 := sx * cos(t1) + sz * sin(t1)
		var n0 := (o0 + dir * slope).normalized()
		var n1 := (o1 + dir * slope).normalized()
		var a0 := a + o0 * ra
		var a1 := a + o1 * ra
		var b0 := b + o0 * rb
		var b1 := b + o1 * rb
		tri(a0, b1, b0, ca, cb, cb, n0, n1, n0, Vector2(ua, 0), Vector2(ub, 0), Vector2(ub, 0))
		tri(a0, a1, b1, ca, ca, cb, n0, n1, n1, Vector2(ua, 0), Vector2(ua, 0), Vector2(ub, 0))
		if cap:
			tri(b, b0, b1, cb, cb, cb, dir, dir, dir, Vector2(ub, 0), Vector2(ub, 0), Vector2(ub, 0))
			tri(a, a1, a0, ca, ca, ca, -dir, -dir, -dir, Vector2(ua, 0), Vector2(ua, 0), Vector2(ua, 0))


func cone(base: Vector3, tip: Vector3, r: float, cbase: Color, ctip: Color, seg := 6) -> void:
	tube(base, tip, r, 0.0005, cbase, ctip, seg, true)


## Flat quad (use a cull-disabled material) with per-corner colors, used for wings, fins, grass blades.
func quad2(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, col2: Color) -> void:
	tri(a, b, c, col, col, col2)
	tri(a, c, d, col, col2, col2)


func commit(mesh: ArrayMesh = null) -> ArrayMesh:
	if mesh == null:
		mesh = ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	if use_uv:
		arr[Mesh.ARRAY_TEX_UV] = uvs
	if use_uv2:
		arr[Mesh.ARRAY_TEX_UV2] = uv2s
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## Textured card: corners a,b,c,d (counter-clockwise), uv rect, per-corner sway, shared normal.
func card(a: Vector3, b: Vector3, c: Vector3, d: Vector3, uv0: Vector2, uv1: Vector2, col: Color, n: Vector3, sw_bottom: float, sw_top: float) -> void:
	# a,b = bottom edge; c,d = top edge
	var ua := Vector2(uv0.x, uv1.y)
	var ub := Vector2(uv1.x, uv1.y)
	var uc := Vector2(uv1.x, uv0.y)
	var ud := Vector2(uv0.x, uv0.y)
	_card_tri(a, b, c, ua, ub, uc, col, n, sw_bottom, sw_bottom, sw_top)
	_card_tri(a, c, d, ua, uc, ud, col, n, sw_bottom, sw_top, sw_top)


func _card_tri(a: Vector3, b: Vector3, c: Vector3, ua: Vector2, ub: Vector2, uc: Vector2, col: Color, n: Vector3, sa: float, sb: float, sc: float) -> void:
	verts.append(a); verts.append(c); verts.append(b)
	norms.append(n); norms.append(n); norms.append(n)
	cols.append(col); cols.append(col); cols.append(col)
	uvs.append(ua); uvs.append(uc); uvs.append(ub)
	uv2s.append(Vector2(sa, 0)); uv2s.append(Vector2(sc, 0)); uv2s.append(Vector2(sb, 0))


static func vc_material(rough := 0.9, shader_mat: Material = null) -> Material:
	if shader_mat != null:
		return shader_mat
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = rough
	return m
