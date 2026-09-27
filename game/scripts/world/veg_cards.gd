class_name VegCards
extends RefCounted
## Textured vegetation: eucalypts with bark + leaf-card canopies, leafy shrubs,
## grass tussock cards and smooth boulders for the triplanar rock shader.


## Eucalypt: bark surface (0) and hanging leaf-card canopy (1). Unit height ~1.
static func tree(rng: RandomNumberGenerator, gum: bool) -> ArrayMesh:
	var bark := MeshBuilder.new()
	bark.use_uv2 = true
	var leaves := MeshBuilder.new()
	leaves.use_uv = true
	leaves.use_uv2 = true
	var trunk_r := 0.045 if gum else 0.035
	var white := Color(0.62, 0.62, 0.62)
	var pts: Array = [Vector3.ZERO]
	var segs := 5
	for i in segs:
		pts.append(Vector3(0, 0.55 * (i + 1) / segs, 0))
	for i in segs:
		var r0 := trunk_r * (1.0 - 0.12 * i) * (1.35 if i == 0 else 1.0)
		var r1 := trunk_r * (1.0 - 0.12 * (i + 1))
		bark.sway_w = 0.0
		bark.tube(pts[i], pts[i + 1], r0, r1, white, white, 12, false)
	for k in 5:
		var a := TAU * k / 5.0 + rng.randf() * 0.4
		bark.tube(Vector3(0, 0.06, 0), Vector3(cos(a) * 0.1, -0.015, sin(a) * 0.1), trunk_r * 0.7, trunk_r * 0.15, white, white, 7, false)
	var top: Vector3 = pts[segs]
	var crowns: Array = []
	var nb := rng.randi_range(4, 6)
	for b in nb:
		var start: Vector3 = pts[rng.randi_range(2, segs)]
		var a2 := TAU * b / nb + rng.randf_range(-0.4, 0.4)
		var out := Vector3(cos(a2), 0, sin(a2))
		var mid := start + out * rng.randf_range(0.1, 0.18) + Vector3(0, rng.randf_range(0.1, 0.2), 0)
		var end := mid + out * rng.randf_range(0.08, 0.16) + Vector3(0, rng.randf_range(0.06, 0.14), 0)
		bark.sway_w = 0.15
		bark.tube(start, mid, trunk_r * 0.5, trunk_r * 0.32, white, white, 8, false)
		bark.sway_w = 0.3
		bark.tube(mid, end, trunk_r * 0.32, trunk_r * 0.14, white, white, 6, false)
		crowns.append(end)
		var tw := end + out.rotated(Vector3.UP, rng.randf_range(-1.2, 1.2)) * 0.1 + Vector3(0, 0.05, 0)
		bark.tube(end, tw, trunk_r * 0.14, trunk_r * 0.06, white, white, 5, false)
		crowns.append(tw)
	crowns.append(top + Vector3(0, 0.1, 0))
	bark.sway_w = 0.0
	var canopy_c := Vector3.ZERO
	for c in crowns:
		canopy_c += c
	canopy_c /= crowns.size()
	for c in crowns:
		var ncards := rng.randi_range(9, 14)
		for i in ncards:
			var cc: Vector3 = c + Vector3(rng.randf_range(-0.1, 0.1), rng.randf_range(-0.04, 0.08), rng.randf_range(-0.1, 0.1))
			var yaw := rng.randf() * TAU
			var right := Vector3(cos(yaw), 0, sin(yaw))
			var down := Vector3(0, -1, 0).rotated(right, rng.randf_range(-0.35, 0.35))
			var w := rng.randf_range(0.13, 0.2)
			var h := rng.randf_range(0.2, 0.3)
			var top_c := cc + Vector3(0, h * 0.35, 0)
			var bot_c := top_c + down * h
			var n := ((cc - canopy_c).normalized() + Vector3.UP * 0.6).normalized()
			var tint := Color(1, 1, 1).lerp(Color(0.85, 0.95, 0.8), rng.randf()) * rng.randf_range(0.85, 1.1)
			var u0 := rng.randf_range(0.0, 0.5)
			leaves.card(bot_c - right * w * 0.5, bot_c + right * w * 0.5, top_c + right * w * 0.5, top_c - right * w * 0.5,
				Vector2(u0, 0.0), Vector2(u0 + 0.5, 1.0), tint, n, 0.6, 0.9)
	var m := bark.commit()
	leaves.commit(m)
	return m


static func shrub(rng: RandomNumberGenerator, dry: bool) -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.use_uv = true
	mb.use_uv2 = true
	var n := rng.randi_range(14, 22)
	for i in n:
		var a := rng.randf() * TAU
		var r := rng.randf_range(0.0, 0.55)
		var cc := Vector3(cos(a) * r, rng.randf_range(0.25, 0.75), sin(a) * r)
		var yaw := rng.randf() * TAU
		var right := Vector3(cos(yaw), 0, sin(yaw))
		var w := rng.randf_range(0.45, 0.7)
		var h := rng.randf_range(0.45, 0.7)
		var up := Vector3.UP.rotated(right, rng.randf_range(-0.5, 0.5))
		var a3 := cc - right * w * 0.5 - up * h * 0.5
		var b3 := cc + right * w * 0.5 - up * h * 0.5
		var c3 := cc + right * w * 0.5 + up * h * 0.5
		var d3 := cc - right * w * 0.5 + up * h * 0.5
		var nn := (cc - Vector3(0, 0.2, 0)).normalized()
		var tint := (Color(1, 1, 1) if not dry else Color(1.1, 1.0, 0.8)) * rng.randf_range(0.8, 1.1)
		var u0 := rng.randf_range(0.0, 0.5)
		var v0 := rng.randf_range(0.0, 0.5)
		mb.card(a3, b3, c3, d3, Vector2(u0, v0), Vector2(u0 + 0.5, v0 + 0.5), tint, nn, clampf(a3.y, 0.0, 1.0), clampf(c3.y, 0.0, 1.0))
	return mb.commit()


static func grass(rng: RandomNumberGenerator, green: bool) -> ArrayMesh:
	var mb := MeshBuilder.new()
	mb.use_uv = true
	mb.use_uv2 = true
	var tint := Color(1, 1, 1) if not green else Color(0.75, 1.0, 0.7)
	for k in 3:
		var yaw := TAU * k / 3.0 + rng.randf_range(-0.2, 0.2)
		var right := Vector3(cos(yaw), 0, sin(yaw))
		var w := rng.randf_range(0.45, 0.6)
		var h := rng.randf_range(0.5, 0.7)
		var lean := Vector3(rng.randf_range(-0.06, 0.06), 0, rng.randf_range(-0.06, 0.06))
		mb.card(-right * w * 0.5, right * w * 0.5, right * w * 0.5 + Vector3(0, h, 0) + lean, -right * w * 0.5 + Vector3(0, h, 0) + lean,
			Vector2(0, 0), Vector2(1, 1), tint * rng.randf_range(0.85, 1.05), Vector3.UP, 0.0, 1.0)
	return mb.commit()


static func rock(rng: RandomNumberGenerator, col: Color) -> ArrayMesh:
	var mb := MeshBuilder.new()
	var c2 := col.darkened(0.15)
	var cf := func(d: Vector3) -> Color:
		return col.lerp(c2, 0.3 + 0.3 * sin(d.y * 6.0))
	mb.ellipsoid(Transform3D.IDENTITY, Vector3.ONE, col, 18, 11, cf, 0.07, rng, false)
	return mb.commit()
