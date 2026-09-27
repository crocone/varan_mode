class_name ReptileHead
extends RefCounted
## Builds detailed skull + lower-jaw meshes for reptiles at unit scale
## (head length = 1 along +Z, mouth line at y = 0, jaw hinge at origin).
## Meshes are cached per species.

static var _cache := {}


static func get_meshes(species: String, base: Color, spot: Color, belly: Color) -> Array:
	if _cache.has(species):
		return _cache[species]
	var r := _build(species, base, spot, belly)
	_cache[species] = r
	return r


static func _loft(mb: MeshBuilder, zs: Array, ws: Array, tops: Array, bots: Array, seg: int, col_fn: Callable, uv_scale: float) -> void:
	var n := zs.size()
	var rings: Array = []
	for i in n:
		var ring: Array = []
		for k in seg + 1:
			var th := TAU * float(k) / seg
			var cs := cos(th)
			var sn := sin(th)
			var hy: float = tops[i] if sn > 0.0 else bots[i]
			var p := Vector3(cs * ws[i], sn * hy, zs[i])
			var nrm := Vector3(cs / maxf(ws[i], 0.001), sn / maxf(hy, 0.001), 0.0).normalized()
			ring.append([p, nrm, col_fn.call(zs[i], th), Vector2(0.002 + zs[i] * uv_scale, float(k) / seg)])
		rings.append(ring)
	for i in n - 1:
		for k in seg:
			var a: Array = rings[i][k]
			var b: Array = rings[i][k + 1]
			var cc: Array = rings[i + 1][k + 1]
			var d: Array = rings[i + 1][k]
			mb.tri(a[0], b[0], cc[0], a[2], b[2], cc[2], a[1], b[1], cc[1], a[3], b[3], cc[3])
			mb.tri(a[0], cc[0], d[0], a[2], cc[2], d[2], a[1], cc[1], d[1], a[3], cc[3], d[3])
	# tip cap
	var last: Array = rings[n - 1]
	var tip := Vector3(0, 0, zs[n - 1] + 0.02)
	for k in seg:
		var a2: Array = last[k]
		var b2: Array = last[k + 1]
		mb.tri(a2[0], b2[0], tip, a2[2], b2[2], a2[2], a2[1], b2[1], Vector3(0, 0, 1), a2[3], b2[3], a2[3])
	# back cap
	var first: Array = rings[0]
	var back := Vector3(0, 0, zs[0])
	for k in seg:
		var a3: Array = first[k]
		var b3: Array = first[k + 1]
		mb.tri(a3[0], back, b3[0], a3[2], a3[2], b3[2], Vector3(0, 0, -1), Vector3(0, 0, -1), Vector3(0, 0, -1))


static func _build(species: String, base: Color, spot: Color, belly: Color) -> Array:
	var skull := MeshBuilder.new()
	skull.use_uv = true
	var jaw := MeshBuilder.new()
	jaw.use_uv = true
	var mouth := Color(0.72, 0.42, 0.42)
	var eye := Color(0.06, 0.045, 0.03)
	var zs: Array
	var ws: Array
	var tops: Array
	var bots: Array
	var jz: Array
	var jw: Array
	var jd: Array
	var eye_p := Vector3(0.24, 0.17, 0.3)
	var eye_r := 0.065
	var teeth := false
	match species:
		"croc":
			zs = [0.0, 0.14, 0.32, 0.55, 0.78, 0.92, 1.0]
			ws = [0.34, 0.33, 0.24, 0.17, 0.15, 0.17, 0.1]
			tops = [0.22, 0.24, 0.13, 0.09, 0.08, 0.09, 0.05]
			bots = [0.03, 0.03, 0.025, 0.02, 0.02, 0.02, 0.015]
			jz = [0.0, 0.2, 0.45, 0.7, 0.9, 0.98]
			jw = [0.3, 0.29, 0.2, 0.15, 0.15, 0.08]
			jd = [0.16, 0.14, 0.09, 0.07, 0.06, 0.03]
			eye_p = Vector3(0.14, 0.26, 0.17)
			eye_r = 0.06
			teeth = true
		"skink":
			zs = [0.0, 0.3, 0.6, 0.85, 1.0]
			ws = [0.48, 0.46, 0.38, 0.26, 0.1]
			tops = [0.4, 0.4, 0.32, 0.22, 0.08]
			bots = [0.05, 0.05, 0.04, 0.03, 0.02]
			jz = [0.0, 0.35, 0.7, 0.95]
			jw = [0.44, 0.4, 0.28, 0.08]
			jd = [0.3, 0.25, 0.15, 0.04]
			eye_p = Vector3(0.38, 0.22, 0.45)
			eye_r = 0.1
		_:
			# lace monitor: long, narrow, flat-topped with a rounded snout
			zs = [0.0, 0.16, 0.34, 0.52, 0.7, 0.86, 0.96, 1.0]
			ws = [0.3, 0.31, 0.27, 0.21, 0.165, 0.13, 0.095, 0.05]
			tops = [0.29, 0.32, 0.29, 0.22, 0.17, 0.13, 0.09, 0.05]
			bots = [0.035, 0.035, 0.03, 0.03, 0.025, 0.02, 0.02, 0.015]
			jz = [0.0, 0.18, 0.42, 0.66, 0.86, 0.97]
			jw = [0.28, 0.27, 0.2, 0.15, 0.1, 0.05]
			jd = [0.22, 0.19, 0.13, 0.09, 0.06, 0.03]
			teeth = true
	var skull_col := func(z: float, th: float) -> Color:
		var up := sin(th)
		if up < -0.35:
			return mouth
		var col := base
		match species:
			"croc":
				if up > 0.5 and fmod(z * 11.0, 1.0) < 0.2:
					col = spot
				if up < 0.2:
					col = col.lerp(belly, 0.35)
			"skink":
				col = base.lightened(0.1)
				if absf(cos(th)) > 0.7 and up > -0.2:
					col = spot
			_:
				# pale transverse snout bands and fine spotting
				var band := fmod(z * 8.5, 1.0)
				if z > 0.45 and band < 0.33 and up > -0.1:
					col = spot.darkened(0.1)
				elif z <= 0.45 and absf(fmod(sin(th * 9.0 + z * 57.0) * 43758.5, 1.0)) > 0.8 and up > 0.1:
					col = spot.darkened(0.2)
				if up < 0.15:
					col = col.lerp(belly, 0.25)
		return col
	_loft(skull, zs, ws, tops, bots, 14, skull_col, 0.12)
	var jaw_col := func(z: float, th: float) -> Color:
		var up := sin(th)
		if up > 0.35:
			return mouth
		var col := belly
		match species:
			"croc":
				col = belly
			"skink":
				col = belly
			_:
				# barred chin
				if fmod(z * 7.0, 1.0) < 0.35:
					col = base.lightened(0.05)
		if up > -0.2 and species != "croc":
			col = col.lerp(base, 0.5)
		return col
	var jbots := jd
	var jtops: Array = []
	for i in jz.size():
		jtops.append(0.02)
	_loft(jaw, jz, jw, jtops, jbots, 12, jaw_col, 0.12)
	# eyes with a brow ridge
	for s in [-1.0, 1.0]:
		var ep := Vector3(eye_p.x * s, eye_p.y, eye_p.z)
		skull.ellipsoid(Transform3D(Basis(), ep), Vector3(eye_r, eye_r, eye_r), eye, 8, 6)
		# golden iris ring hint
		skull.ellipsoid(Transform3D(Basis(), ep - Vector3(0.01 * s, 0.0, 0.0)), Vector3(eye_r * 1.12, eye_r * 0.8, eye_r * 1.05), Color(0.55, 0.42, 0.18), 8, 4)
		skull.ellipsoid(Transform3D(Basis(), ep + Vector3(-0.02 * s, eye_r * 0.75, 0.01)), Vector3(eye_r * 1.3, eye_r * 0.45, eye_r * 1.5), base, 7, 4)
		# nostril
		var np := Vector3(0.075 * s, 0.07, 0.9) if species != "croc" else Vector3(0.04 * s, 0.08, 0.95)
		skull.ellipsoid(Transform3D(Basis(), np), Vector3(0.025, 0.018, 0.03), Color(0.03, 0.02, 0.02), 6, 4)
	if teeth:
		var tooth := Color(0.78, 0.74, 0.64)
		var zz := 0.18
		while zz < 0.93:
			var wi: float = _interp(zs, ws, zz) * 0.93
			for s in [-1.0, 1.0]:
				var tp := Vector3(wi * s, -0.005, zz)
				skull.cone(tp, tp + Vector3(0, -0.06 if species == "croc" else -0.035, 0.005), 0.014, tooth, tooth, 4)
				var wj: float = _interp(jz, jw, zz - 0.02) * 0.9
				var jp := Vector3(wj * s, 0.015, zz - 0.02)
				jaw.cone(jp, jp + Vector3(0, 0.05 if species == "croc" else 0.03, 0.005), 0.012, tooth, tooth, 4)
			zz += 0.09 if species == "croc" else 0.11
	return [skull.commit(), jaw.commit()]


static func _interp(zs: Array, vals: Array, z: float) -> float:
	for i in zs.size() - 1:
		if z >= zs[i] and z <= zs[i + 1]:
			return lerpf(vals[i], vals[i + 1], (z - zs[i]) / maxf(0.0001, zs[i + 1] - zs[i]))
	return vals[vals.size() - 1]
