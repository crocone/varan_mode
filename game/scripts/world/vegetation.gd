class_name Vegetation
extends RefCounted
## Procedural meshes for the static world: eucalypts, shrubs, spinifex,
## grass tufts, reeds, rocks, logs and mounds. All vertex-colored.

const BARK_GUM := Color(0.86, 0.83, 0.76)
const BARK_EUC := Color(0.55, 0.47, 0.40)
const LEAF_A := Color(0.36, 0.43, 0.27)
const LEAF_B := Color(0.46, 0.50, 0.33)
const LEAF_C := Color(0.30, 0.37, 0.25)


## Eucalypt: crooked trunk, a few branches, clumped grey-green canopy.
## Built at unit scale (height ~1), uv.x = sway weight.
static func tree(rng: RandomNumberGenerator, gum: bool) -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.use_uv = true
	var bark := BARK_GUM if gum else BARK_EUC
	var bark_dark := bark.darkened(0.25)
	var trunk_r := 0.045 if gum else 0.035
	var pts: Array = [Vector3.ZERO]
	var p := Vector3.ZERO
	# straight trunk (climbable surface must match Terrain.trunk_radius)
	var segs := 5
	for i in segs:
		p += Vector3(0, 0.55 / segs, 0)
		pts.append(p)
	for i in segs:
		var r0 := trunk_r * (1.0 - 0.12 * i) * (1.35 if i == 0 else 1.0)
		var r1 := trunk_r * (1.0 - 0.12 * (i + 1))
		mb.tube(pts[i], pts[i + 1], r0, r1, bark_dark.lerp(bark, float(i) / segs), bark, 7, false, 0.0, 0.0)
	# root flare
	for k in 4:
		var a := TAU * k / 4.0 + rng.randf() * 0.5
		mb.tube(Vector3(0, 0.05, 0), Vector3(cos(a) * 0.09, -0.01, sin(a) * 0.09), trunk_r * 0.6, trunk_r * 0.15, bark_dark, bark_dark, 5, false)
	var top: Vector3 = pts[segs]
	var crowns: Array = []
	var nb := rng.randi_range(3, 5)
	for b in nb:
		var start: Vector3 = pts[rng.randi_range(2, segs)]
		var a2 := TAU * b / nb + rng.randf_range(-0.4, 0.4)
		var out := Vector3(cos(a2), 0, sin(a2))
		var end := start + out * rng.randf_range(0.18, 0.32) + Vector3(0, rng.randf_range(0.18, 0.35), 0)
		mb.tube(start, end, trunk_r * 0.5, trunk_r * 0.2, bark, bark, 5, false, 0.0, 0.3)
		crowns.append(end)
	crowns.append(top + Vector3(0, 0.08, 0))
	for c in crowns:
		var nclump := rng.randi_range(2, 4)
		for k in nclump:
			var cp: Vector3 = c + Vector3(rng.randf_range(-0.12, 0.12), rng.randf_range(-0.03, 0.08), rng.randf_range(-0.12, 0.12))
			var rad := Vector3(rng.randf_range(0.13, 0.22), rng.randf_range(0.06, 0.1), rng.randf_range(0.13, 0.22))
			var col := LEAF_A.lerp(LEAF_B if rng.randf() < 0.5 else LEAF_C, rng.randf())
			_clump(mb, cp, rad, col, rng)
	return mb.commit()


static func _clump(mb: MeshBuilder, center: Vector3, rad: Vector3, col: Color, rng: RandomNumberGenerator) -> void:
	var xf := Transform3D(Basis(Vector3.UP, rng.randf() * TAU), center)
	var start := mb.verts.size()
	mb.ellipsoid(xf, rad, col, 7, 4, func(d: Vector3) -> Color: return col.darkened(0.3 - d.y * 0.3), 0.18, rng, true)
	for i in range(start, mb.uvs.size()):
		mb.uvs[i] = Vector2(0.6, 0)


static func shrub(rng: RandomNumberGenerator, dry: bool) -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.use_uv = true
	var n := rng.randi_range(4, 7)
	var base_col := Color(0.42, 0.46, 0.28) if not dry else Color(0.55, 0.5, 0.32)
	for k in n:
		var a := rng.randf() * TAU
		var r := rng.randf_range(0.0, 0.45)
		var c := Vector3(cos(a) * r, rng.randf_range(0.25, 0.55), sin(a) * r)
		var rad := Vector3(rng.randf_range(0.3, 0.5), rng.randf_range(0.25, 0.4), rng.randf_range(0.3, 0.5))
		var col := base_col.lerp(Color(0.3, 0.36, 0.22), rng.randf() * 0.6)
		var start := mb.verts.size()
		var xf := Transform3D(Basis(Vector3.UP, rng.randf() * TAU), c)
		mb.ellipsoid(xf, rad, col, 7, 4, func(d: Vector3) -> Color: return col.darkened(0.35 - d.y * 0.35), 0.22, rng, true)
		for i in range(start, mb.uvs.size()):
			mb.uvs[i] = Vector2(clampf(mb.verts[i].y * 0.6, 0.0, 1.0), 0)
	return mb.commit()


## Spinifex hummock: dome of spiky straw-colored blades.
static func spinifex(rng: RandomNumberGenerator) -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.use_uv = true
	var n := 70
	for k in n:
		var a := rng.randf() * TAU
		var tilt := rng.randf_range(0.1, 1.2)
		var len := rng.randf_range(0.45, 0.75)
		var dir := Vector3(cos(a) * sin(tilt), cos(tilt), sin(a) * sin(tilt))
		var base := Vector3(cos(a) * 0.08, 0.0, sin(a) * 0.08)
		var side := Vector3(-sin(a), 0, cos(a)) * 0.025
		var tip := base + dir * len
		var c0 := Color(0.52, 0.5, 0.3)
		var c1 := Color(0.82, 0.74, 0.46).lerp(Color(0.6, 0.62, 0.38), rng.randf())
		mb.tri(base - side, base + side, tip, c0, c0, c1, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2(1, 0))
	# the up normals give soft lighting for blades
	for i in mb.norms.size():
		mb.norms[i] = Vector3(mb.verts[i].x, 1.5, mb.verts[i].z).normalized()
	return mb.commit()


static func grass_tuft(rng: RandomNumberGenerator, green: bool) -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.use_uv = true
	var n := 9
	for k in n:
		var a := rng.randf() * TAU
		var tilt := rng.randf_range(0.05, 0.6)
		var len := rng.randf_range(0.35, 0.7)
		var dir := Vector3(cos(a) * sin(tilt), cos(tilt), sin(a) * sin(tilt))
		var base := Vector3(cos(a) * 0.05, 0.0, sin(a) * 0.05)
		var side := Vector3(-sin(a), 0, cos(a)) * 0.02
		var mid := base + dir * len * 0.5 + Vector3(0, 0, 0)
		var tip := base + dir * len + Vector3(cos(a), 0, sin(a)) * 0.08
		var c0 := Color(0.45, 0.4, 0.22) if not green else Color(0.3, 0.36, 0.18)
		var c1 := Color(0.85, 0.76, 0.48) if not green else Color(0.55, 0.6, 0.32)
		c1 = c1.lerp(Color(0.72, 0.62, 0.38), rng.randf() * 0.5)
		var cm := c0.lerp(c1, 0.5)
		mb.tri(base - side, base + side, mid + side * 0.7, c0, c0, cm, Vector3.UP, Vector3.UP, Vector3.UP, Vector2.ZERO, Vector2.ZERO, Vector2(0.5, 0))
		mb.tri(base - side, mid + side * 0.7, mid - side * 0.7, c0, cm, cm, Vector3.UP, Vector3.UP, Vector3.UP, Vector2.ZERO, Vector2(0.5, 0), Vector2(0.5, 0))
		mb.tri(mid - side * 0.7, mid + side * 0.7, tip, cm, cm, c1, Vector3.UP, Vector3.UP, Vector3.UP, Vector2(0.5, 0), Vector2(0.5, 0), Vector2(1, 0))
	return mb.commit()


static func reed(rng: RandomNumberGenerator) -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.use_uv = true
	for k in 7:
		var base := Vector3(rng.randf_range(-0.15, 0.15), 0, rng.randf_range(-0.15, 0.15))
		var tip := base + Vector3(rng.randf_range(-0.2, 0.2), rng.randf_range(1.0, 1.8), rng.randf_range(-0.2, 0.2))
		var side := Vector3(0.02, 0, 0.0).rotated(Vector3.UP, rng.randf() * TAU)
		var c0 := Color(0.3, 0.36, 0.2)
		var c1 := Color(0.55, 0.58, 0.32)
		mb.tri(base - side, base + side, tip, c0, c0, c1, Vector3.UP, Vector3.UP, Vector3.UP, Vector2.ZERO, Vector2.ZERO, Vector2(1, 0))
		if rng.randf() < 0.4:
			mb.tube(tip - (tip - base) * 0.12, tip, 0.025, 0.02, Color(0.35, 0.22, 0.12), Color(0.3, 0.2, 0.1), 5, true, 1.0, 1.0)
	return mb.commit()


static func rock(rng: RandomNumberGenerator, col: Color) -> ArrayMesh:
	var mb := MeshBuilder.new()
	var c2 := col.darkened(0.2)
	var cf := func(d: Vector3) -> Color:
		var strata := 0.5 + 0.5 * sin(d.y * 9.0)
		return col.lerp(c2, strata * 0.5 + (0.3 if d.y < 0.0 else 0.0))
	mb.ellipsoid(Transform3D.IDENTITY, Vector3.ONE, col, 9, 6, cf, 0.12, rng, true)
	return mb.commit()


## Smooth basking slab; its surface matches Terrain's analytic ellipsoid.
static func slab_rock(col: Color) -> ArrayMesh:
	var mb := MeshBuilder.new()
	var c2 := col.darkened(0.18)
	var cf := func(d: Vector3) -> Color:
		var strata := 0.5 + 0.5 * sin(d.y * 7.0 + d.x * 2.0)
		return col.lerp(c2, strata * 0.4)
	mb.ellipsoid(Transform3D.IDENTITY, Vector3.ONE * 1.01, col, 20, 10, cf)
	return mb.commit()


static func log_mesh(rng: RandomNumberGenerator) -> ArrayMesh:
	# unit log along +Z from -0.5..0.5, radius 1 (scaled by instance)
	var mb := MeshBuilder.new()
	var bark := Color(0.42, 0.34, 0.27)
	var inner := Color(0.12, 0.08, 0.06)
	var seg := 9
	var rings := 6
	for r in rings:
		var z0 := -0.5 + float(r) / rings
		var z1 := -0.5 + float(r + 1) / rings
		for s in seg:
			var t0 := TAU * s / seg
			var t1 := TAU * (s + 1) / seg
			var j0 := 1.0 + sin(t0 * 3.0 + r) * 0.06
			var j1 := 1.0 + sin(t1 * 3.0 + r) * 0.06
			var a := Vector3(cos(t0) * j0, sin(t0) * j0, z0)
			var b := Vector3(cos(t1) * j1, sin(t1) * j1, z0)
			var c := Vector3(cos(t1) * j1, sin(t1) * j1, z1)
			var d := Vector3(cos(t0) * j0, sin(t0) * j0, z1)
			var cc := bark.darkened(0.15 * sin(t0 * 5.0 + r * 2.0) + 0.1)
			mb.tri(a, d, c, cc, cc, cc)
			mb.tri(a, c, b, cc, cc, cc)
			# inner hollow surface (dark), smaller radius, reversed
			var ia := a * Vector3(0.72, 0.72, 1)
			var ib := b * Vector3(0.72, 0.72, 1)
			var ic := c * Vector3(0.72, 0.72, 1)
			var id := d * Vector3(0.72, 0.72, 1)
			mb.tri(ia, ic, id, inner, inner, inner)
			mb.tri(ia, ib, ic, inner, inner, inner)
	# end rims
	for z in [-0.5, 0.5]:
		for s in seg:
			var t0 := TAU * s / seg
			var t1 := TAU * (s + 1) / seg
			var o0 := Vector3(cos(t0), sin(t0), z)
			var o1 := Vector3(cos(t1), sin(t1), z)
			var i0 := o0 * Vector3(0.72, 0.72, 1)
			var i1 := o1 * Vector3(0.72, 0.72, 1)
			var rc := Color(0.6, 0.48, 0.34)
			if z > 0:
				mb.tri(o0, o1, i1, rc, rc, rc)
				mb.tri(o0, i1, i0, rc, rc, rc)
			else:
				mb.tri(o0, i1, o1, rc, rc, rc)
				mb.tri(o0, i0, i1, rc, rc, rc)
	return mb.commit()


static func termite_mound(rng: RandomNumberGenerator) -> ArrayMesh:
	var mb := MeshBuilder.new()
	var col := Color(0.72, 0.42, 0.24)
	# stacked lumpy ellipsoids forming a spire
	var levels := 5
	for i in levels:
		var t := float(i) / levels
		var c := Vector3(rng.randf_range(-0.05, 0.05), t * 0.85, rng.randf_range(-0.05, 0.05))
		var r := lerpf(0.55, 0.12, t)
		mb.ellipsoid(Transform3D(Basis(), c), Vector3(r, 0.28, r * rng.randf_range(0.85, 1.1)), col.darkened(t * 0.1), 14, 8, func(d: Vector3) -> Color: return col.darkened(0.15 + d.y * -0.1 + randf() * 0.05), 0.1, rng, false)
	# a few side spires
	for k in 2:
		var a := rng.randf() * TAU
		var c2 := Vector3(cos(a) * 0.3, 0.3, sin(a) * 0.3)
		mb.ellipsoid(Transform3D(Basis(), c2), Vector3(0.15, 0.4, 0.15), col.darkened(0.05), 10, 6, null, 0.1, rng, false)
	# entrance hole
	mb.ellipsoid(Transform3D(Basis(), Vector3(0.0, 0.08, 0.5)), Vector3(0.12, 0.08, 0.06), Color(0.08, 0.05, 0.04), 6, 4, null, 0.0, null, true)
	return mb.commit()


static func turkey_mound(rng: RandomNumberGenerator) -> ArrayMesh:
	var mb := MeshBuilder.new()
	var col := Color(0.36, 0.27, 0.19)
	var cf := func(d: Vector3) -> Color:
		var n := randf()
		return col.lerp(Color(0.5, 0.38, 0.24), n * 0.6).lerp(Color(0.4, 0.42, 0.25), 0.2 if n > 0.8 else 0.0)
	mb.ellipsoid(Transform3D(Basis(), Vector3(0, -0.2, 0)), Vector3(1.0, 0.7, 1.0), col, 12, 6, cf, 0.08, rng, true)
	return mb.commit()


static func pebbles(rng: RandomNumberGenerator) -> ArrayMesh:
	var mb := MeshBuilder.new()
	for k in 5:
		var c := Vector3(rng.randf_range(-0.4, 0.4), 0.0, rng.randf_range(-0.4, 0.4))
		var s := rng.randf_range(0.03, 0.09)
		var col := Color(0.62, 0.45, 0.35).lerp(Color(0.8, 0.75, 0.66), rng.randf())
		mb.ellipsoid(Transform3D(Basis(Vector3.UP, rng.randf() * TAU), c), Vector3(s, s * 0.6, s * 1.2), col, 5, 3, null, 0.2, rng, true)
	# leaf litter / twigs
	for k in 3:
		var a := Vector3(rng.randf_range(-0.5, 0.5), 0.01, rng.randf_range(-0.5, 0.5))
		var b := a + Vector3(rng.randf_range(-0.3, 0.3), 0.0, rng.randf_range(-0.3, 0.3))
		mb.tube(a, b, 0.012, 0.008, Color(0.4, 0.3, 0.22), Color(0.45, 0.35, 0.25), 4, false)
	return mb.commit()


static func egg_mesh() -> ArrayMesh:
	var mb := MeshBuilder.new()
	var col := Color(0.93, 0.9, 0.82)
	mb.ellipsoid(Transform3D.IDENTITY, Vector3(0.7, 1.0, 0.7), col, 10, 7, func(d: Vector3) -> Color: return col.darkened(0.08 - d.y * 0.08))
	return mb.commit()
