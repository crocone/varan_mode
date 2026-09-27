class_name BirdRig
extends Node3D
## Procedural bird rig: rigid vertex-coloured parts on joint pivots.
## Kinds (sp.bird): "turkey" (brush-turkey, ground bird with a vertical fan
## tail), "crow" (raven: walks, hops, flies) and "eagle" (wedge-tailed eagle:
## soars on flat wings, flaps only when climbing). Meshes are built once per
## species in normalised units (creature length = 1) and shared; the rig node
## is scaled by creature.length. Local +Z forward, +Y up, +X = left side.

static var _cache := {}
static var _mats := {}

var c: Creature
var kind := "crow"
var root := Node3D.new()        # ground offset, terrain pitch, bank / death roll
var body := Node3D.new()        # pivot at the hips: posture tilt
var body_mi: MeshInstance3D
var neck: Node3D
var head: Node3D
var tail: Node3D
var wings: Array[Node3D] = []           # shoulder pivots (0 = left/+X, 1 = right/-X)
var wing_inner: Array[MeshInstance3D] = []
var wrists: Array[Node3D] = []
var fold_q: Array[Quaternion] = []
var legs: Array[Node3D] = []            # hip pivots
var ankles: Array[Node3D] = []
var feet: Array[Node3D] = []

# shape parameters (normalised)
var hip := Vector3(0, 0.36, -0.03)
var tib_len := 0.17
var tar_len := 0.2
var tib_rest := 0.45
var tar_rest := -0.25
var toe_r := 0.012
var body_clear := 0.1          # min hip height when sitting
var stand_tilt := -0.05
var neck_world := -1.1
var neck_fly := -0.2
var neck_peck := 0.9
var tail_world := 0.0
var tail_fly := 0.0
var span_in := 0.3
var flap_freq := 6.0
var flap_amp := 0.9
var dihedral := 0.06
var tip_up := 0.0
var fold_in_scale := 0.3
var stride0 := 0.8
var stride1 := 1.6

# state
var phase := 0.0
var _last_gp := 0.0
var t := 0.0
var move_w := 0.0
var run_w := 0.0
var eat_w := 0.0
var open := 0.0
var fly_w := 0.0
var flap_amt := 0.0
var flap_ph := 0.0
var glide_timer := 0.0
var vy := 0.0
var _prev_y := 0.0
var _prev_yaw := 0.0
var bank := 0.0
var t_pitch := 0.0
var tilt := 0.0
var head_yaw := 0.0
var head_roll := 0.0
var look_timer := 1.0
var look_goal := 0.0
var look_roll := 0.0
var bite_t := -1.0
var hit_t := 0.0
var dead := false
var dead_amt := 0.0
var hop_w := 0.0


func setup(creature: Creature) -> void:
	c = creature
	kind = c.sp.get("bird", "crow")
	add_child(root)
	root.add_child(body)
	match kind:
		"turkey":
			_build_turkey()
		"eagle":
			_build_eagle()
		_:
			_build_crow()
	on_resize()
	_last_gp = c.gait_phase
	_prev_y = c.position.y
	_prev_yaw = c.yaw
	open = 1.0 if c.flying else 0.0
	fly_w = open
	flap_ph = randf() * TAU
	phase = randf()
	t = randf() * 10.0


func on_resize() -> void:
	scale = Vector3.ONE * maxf(c.length, 0.001)


func on_action(a: String) -> void:
	if a == "bite":
		bite_t = 0.0


func on_hit() -> void:
	hit_t = 0.3


func on_death() -> void:
	dead = true


# ================================================================ helpers

static func _ss(a: float, b: float, x: float) -> float:
	var k := clampf((x - a) / (b - a), 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)


static func _hash3(d: Vector3) -> float:
	return fposmod(sin(d.x * 12.9898 + d.y * 78.233 + d.z * 37.719) * 43758.5453, 1.0)


static func _vary(col: Color, d: Vector3, amt := 0.1) -> Color:
	var k := 1.0 + (_hash3(d) - 0.5) * amt
	return Color(col.r * k, col.g * k, col.b * k)


static func _otri(mb: MeshBuilder, a: Vector3, b: Vector3, cc: Vector3, col: Color, want: Vector3) -> void:
	if (b - a).cross(cc - a).dot(want) < 0.0:
		mb.tri(a, cc, b, col, col, col)
	else:
		mb.tri(a, b, cc, col, col, col)


## Flat slab from a star-shaped 2D outline (x, z) with thickness along local Y.
static func _slab(mb: MeshBuilder, xf: Transform3D, pts: PackedVector2Array, thick: float, ctop: Color, cbot: Color, cedge := Color(-1, 0, 0)) -> void:
	var n := pts.size()
	var cen := Vector2.ZERO
	for p in pts:
		cen += p
	cen /= n
	var up := xf.basis * Vector3.UP
	var h := thick * 0.5
	var top := PackedVector3Array()
	var bot := PackedVector3Array()
	for p in pts:
		top.append(xf * Vector3(p.x, h, p.y))
		bot.append(xf * Vector3(p.x, -h, p.y))
	var ct := xf * Vector3(cen.x, h, cen.y)
	var cb := xf * Vector3(cen.x, -h, cen.y)
	var mid := (ct + cb) * 0.5
	var ce := ctop.darkened(0.15) if cedge.r < 0.0 else cedge
	for i in n:
		var j := (i + 1) % n
		_otri(mb, ct, top[i], top[j], ctop, up)
		_otri(mb, cb, bot[i], bot[j], cbot, -up)
		var out := (top[i] + top[j]) * 0.5 - ct
		_otri(mb, top[i], bot[i], bot[j], ce, out)
		_otri(mb, top[i], bot[j], top[j], ce, out)


static func _mirror(pts: PackedVector2Array, s: float) -> PackedVector2Array:
	var r := PackedVector2Array()
	for p in pts:
		r.append(Vector2(p.x * s, p.y))
	return r


static func _get_mat(rough: float) -> StandardMaterial3D:
	var k := int(rough * 100.0)
	if not _mats.has(k):
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		m.roughness = rough
		_mats[k] = m
	return _mats[k]


func _mesh(key: String, build: Callable) -> ArrayMesh:
	var k := c.species_id + "/" + key
	var m: ArrayMesh = _cache.get(k)
	if m == null:
		var mb := MeshBuilder.new()
		build.call(mb)
		m = mb.commit()
		m.resource_name = key
		_cache[k] = m
	return m


func _node(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


func _add_mesh(parent: Node3D, key: String, build: Callable) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh(key, build)
	mi.material_override = _get_mat(0.55 if kind == "crow" else 0.85)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mi)
	return mi


## Feathered body colour: `top` fading to `under` below, with feather noise.
static func _plume(top: Color, under: Color, thr := -0.4, noise := 0.18) -> Callable:
	return func(d: Vector3) -> Color:
		return _vary(top.lerp(under, _ss(thr, thr - 0.4, d.y)), d, noise)


static func _lgrad(c0: Color, c1: Color, a := 0.0, b := 1.0) -> Callable:
	return func(tt: float, cs: float, sn: float) -> Color:
		return _vary(c0.lerp(c1, _ss(a, b, tt)), Vector3(tt * 5.0, cs, sn), 0.06)


static func _cr(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, f: float) -> Vector3:
	var f2 := f * f
	var f3 := f2 * f
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * f + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * f3)


static func _ntri(mb: MeshBuilder, pa: Vector3, pb: Vector3, pc: Vector3, na: Vector3, nb: Vector3, nc: Vector3, ca: Color, cb: Color, cc: Color) -> void:
	if (pb - pa).cross(pc - pa).dot(na + nb + nc) < 0.0:
		mb.tri(pa, pc, pb, ca, cc, cb, na, nc, nb)
	else:
		mb.tri(pa, pb, pc, ca, cb, cc, na, nb, nc)


static func _loft(mb: MeshBuilder, pts: PackedVector3Array, sizes: PackedVector3Array, ref_up: Vector3, sides: int, col_fn: Callable, sub := 2, caps := true) -> void:
	var n := pts.size()
	var cp := PackedVector3Array()
	var csz := PackedVector3Array()
	for i in n - 1:
		var i0 := maxi(i - 1, 0)
		var i3 := mini(i + 2, n - 1)
		for k in sub:
			var f := float(k) / sub
			cp.append(_cr(pts[i0], pts[i], pts[i + 1], pts[i3], f))
			var s := _cr(sizes[i0], sizes[i], sizes[i + 1], sizes[i3], f)
			csz.append(Vector3(maxf(s.x, 0.0004), maxf(s.y, 0.0004), maxf(s.z, 0.0004)))
	cp.append(pts[n - 1])
	csz.append(sizes[n - 1])
	var m := cp.size()
	var acc := PackedFloat32Array()
	acc.resize(m)
	for i in range(1, m):
		acc[i] = acc[i - 1] + cp[i].distance_to(cp[i - 1])
	var total := maxf(acc[m - 1], 0.00001)
	var rp := PackedVector3Array()
	var rn := PackedVector3Array()
	var rc := PackedColorArray()
	var tans := PackedVector3Array()
	var prev_up := ref_up
	for i in m:
		var tan := (cp[mini(i + 1, m - 1)] - cp[maxi(i - 1, 0)]).normalized()
		var up := ref_up - tan * ref_up.dot(tan)
		if up.length_squared() < 0.000001:
			up = prev_up
		up = up.normalized()
		prev_up = up
		var side := up.cross(tan).normalized()
		var sz := csz[i]
		var tt := acc[i] / total
		for k in sides:
			var th := TAU * k / sides
			var cx := cos(th)
			var sy := sin(th)
			var hh := sz.y if sy >= 0.0 else sz.z
			rp.append(cp[i] + side * (cx * sz.x) + up * (sy * hh))
			rn.append((side * (cx / sz.x) + up * (sy / hh)).normalized())
			rc.append(col_fn.call(tt, cx, sy))
		tans.append(tan)
	for i in m - 1:
		for k in sides:
			var a := i * sides + k
			var b := i * sides + (k + 1) % sides
			var c2 := b + sides
			var d := a + sides
			_ntri(mb, rp[a], rp[b], rp[c2], rn[a], rn[b], rn[c2], rc[a], rc[b], rc[c2])
			_ntri(mb, rp[a], rp[c2], rp[d], rn[a], rn[c2], rn[d], rc[a], rc[c2], rc[d])
	if caps:
		for e in [0, m - 1]:
			var dir: Vector3 = -tans[0] if e == 0 else tans[m - 1]
			var sz: Vector3 = csz[e]
			var tip: Vector3 = cp[e] + dir * minf(sz.x, (sz.y + sz.z) * 0.5) * 0.6
			var tc: Color = col_fn.call(0.0 if e == 0 else 1.0, 0.0, 0.0)
			for k in sides:
				var a: int = e * sides + k
				var b: int = e * sides + (k + 1) % sides
				_ntri(mb, rp[a], rp[b], tip, rn[a], rn[b], dir, rc[a], rc[b], tc)


static func _body(mb: MeshBuilder, keys: Array, sides: int, col_fn: Callable, sub := 2, off := Vector3.ZERO, caps := true) -> void:
	var pts := PackedVector3Array()
	var sz := PackedVector3Array()
	for k in keys:
		pts.append(Vector3(k[0], k[1], k[2]) - off)
		sz.append(Vector3(k[3], k[4], k[5]))
	_loft(mb, pts, sz, Vector3.UP, sides, col_fn, sub, caps)


## Wing: inner (arm) panel + outer (hand) panel on a wrist pivot.
## fingers = 0 gives a rounded tip; otherwise separated primaries.
func _build_wings(shoulder: Vector3, s_in: float, ch_in: float, s_out: float, ch_out: float, fingers: int, finger_len: float, ctop: Color, cbot: Color, thick: float) -> void:
	span_in = s_in
	for i in 2:
		var s := 1.0 if i == 0 else -1.0
		var sh := _node(body, Vector3(shoulder.x * s, shoulder.y, shoulder.z))
		var side := "L" if s > 0 else "R"
		var mi := _add_mesh(sh, "wing_in" + side, func(mb: MeshBuilder) -> void:
			var p := PackedVector2Array([Vector2(0, 0.03), Vector2(s_in * 0.5, 0.035), Vector2(s_in, 0.02), Vector2(s_in, -ch_in * 0.95), Vector2(s_in * 0.55, -ch_in), Vector2(0, -ch_in * 0.8)])
			_slab(mb, Transform3D(), _mirror(p, s), thick, ctop, cbot)
			# covert band on top
			var p2 := PackedVector2Array([Vector2(0, 0.03), Vector2(s_in, 0.02), Vector2(s_in, -ch_in * 0.4), Vector2(0, -ch_in * 0.4)])
			_slab(mb, Transform3D(Basis(), Vector3(0, thick * 0.35, 0)), _mirror(p2, s), thick * 0.6, ctop.lightened(0.06), cbot)
		)
		var wr := _node(sh, Vector3(s_in * s, 0, 0))
		_add_mesh(wr, "wing_out" + side, func(mb: MeshBuilder) -> void:
			if fingers <= 0:
				var p := PackedVector2Array([Vector2(0, 0.02), Vector2(s_out * 0.6, 0.0), Vector2(s_out * 0.92, -ch_out * 0.25), Vector2(s_out, -ch_out * 0.55), Vector2(s_out * 0.85, -ch_out * 0.85), Vector2(s_out * 0.45, -ch_out * 0.97), Vector2(0, -ch_out * 0.95)])
				_slab(mb, Transform3D(), _mirror(p, s), thick * 0.8, ctop, cbot)
			else:
				var base := s_out - finger_len
				var p := PackedVector2Array([Vector2(0, 0.02), Vector2(base, 0.0), Vector2(base + 0.02, -ch_out * 0.5), Vector2(base, -ch_out * 0.95), Vector2(0, -ch_out * 0.95)])
				_slab(mb, Transform3D(), _mirror(p, s), thick * 0.8, ctop, cbot)
				for f in fingers:
					var ff := float(f) / maxf(1.0, fingers - 1)
					var z0 := lerpf(-0.01, -ch_out * 0.8, ff)
					var w := ch_out * 0.8 / fingers * 0.95
					var ln := finger_len * lerpf(1.0, 0.72, ff)
					var ang := lerpf(0.05, -0.55, ff)
					var dir := Vector2(cos(ang), sin(ang))
					var root_pt := Vector2(base - 0.02, z0)
					var tip := root_pt + dir * ln
					var nrm := Vector2(-dir.y, dir.x)
					var q := PackedVector2Array([root_pt + nrm * w * 0.5, tip + nrm * w * 0.22, tip - nrm * w * 0.18, root_pt - nrm * w * 0.5])
					_slab(mb, Transform3D(Basis(), Vector3(0, -0.002 * f, 0)), _mirror(q, s), thick * 0.5, ctop.darkened(0.1), cbot.darkened(0.1))
		)
		wings.append(sh)
		wing_inner.append(mi)
		wrists.append(wr)
		# folded orientation: span pointing back, chord hanging down and slightly out
		var bx := Vector3(0, 0, -s)
		var bz := Vector3(-s * 0.4, 0.92, 0.0).normalized()
		var by := bz.cross(bx)
		fold_q.append(Basis(bx, by, bz).orthonormalized().get_rotation_quaternion())


func _build_legs(xoff: float, tib_col: Color, tib_feather: Vector3, tar_col: Color, tar_r: float, toe_col: Color, toe_len: float, claw: Color) -> void:
	for i in 2:
		var s := 1.0 if i == 0 else -1.0
		var hp := _node(root, Vector3(xoff * s, hip.y, hip.z))
		_add_mesh(hp, "tib", func(mb: MeshBuilder) -> void:
			mb.ellipsoid(Transform3D(Basis(), Vector3(0, -tib_len * 0.45, 0)), tib_feather, tib_col, 8, 5, _plume(tib_col, tib_col.lightened(0.05), -0.9))
			if kind == "eagle":
				# shaggy feathered "trousers"
				for f in 8:
					var a := TAU * f / 8.0
					var rb := Vector3(cos(a) * tib_feather.x * 0.8, -tib_len * 0.75, sin(a) * tib_feather.z * 0.8)
					mb.cone(rb, rb * Vector3(1.25, 1.0, 1.25) + Vector3(0, -tib_len * 0.5, -0.01), tib_feather.x * 0.45, tib_col, tib_col.darkened(0.2), 4)
			mb.tube(Vector3.ZERO, Vector3(0, -tib_len, 0), tar_r * 1.4, tar_r * 1.1, tib_col, tar_col, 6, false)
		)
		var an := _node(hp, Vector3(0, -tib_len, 0))
		_add_mesh(an, "tar", func(mb: MeshBuilder) -> void:
			mb.ellipsoid(Transform3D(Basis(), Vector3.ZERO), Vector3.ONE * tar_r * 1.15, tar_col, 6, 4)
			mb.tube(Vector3.ZERO, Vector3(0, -tar_len, 0), tar_r, tar_r * 0.85, tar_col, tar_col, 6, false)
			if kind == "eagle":
				# feathered tarsus
				mb.ellipsoid(Transform3D(Basis(), Vector3(0, -tar_len * 0.45, 0)), Vector3(tar_r * 1.6, tar_len * 0.55, tar_r * 1.7), tib_col, 7, 4, _plume(tib_col, tib_col, -0.9))
		)
		var ft := _node(an, Vector3(0, -tar_len, 0))
		_add_mesh(ft, "foot", func(mb: MeshBuilder) -> void:
			var tr := toe_r
			var y := -tr * 0.4
			mb.ellipsoid(Transform3D(Basis(), Vector3(0, y, 0)), Vector3.ONE * tr * 1.3, toe_col, 6, 3)
			for a in [-0.5, 0.0, 0.5]:
				var d := Vector3(sin(a), 0, cos(a))
				var ln := toe_len * (1.0 if a == 0.0 else 0.8)
				mb.tube(Vector3(0, y, 0), Vector3(0, y, 0) + d * ln, tr, tr * 0.7, toe_col, toe_col, 5, false)
				mb.cone(Vector3(0, y, 0) + d * ln, Vector3(0, y - tr * 0.8, 0) + d * (ln + tr * 2.2), tr * 0.6, claw, claw, 4)
			mb.tube(Vector3(0, y, 0), Vector3(0, y, -toe_len * 0.5), tr, tr * 0.7, toe_col, toe_col, 5, false)
			mb.cone(Vector3(0, y, -toe_len * 0.5), Vector3(0, y - tr * 0.8, -toe_len * 0.5 - tr * 2.2), tr * 0.6, claw, claw, 4)
		)
		legs.append(hp)
		ankles.append(an)
		feet.append(ft)


# ================================================================ species

## Folded wing baked into the body: a flattened loft hugging each flank from the
## shoulder back over the tail. keys: [x, y, z, half_thick, up, down] for the +X side.
static func _folded_wings(mb: MeshBuilder, keys: Array, off: Vector3, col_fn: Callable) -> void:
	for s in [1.0, -1.0]:
		var k2: Array = []
		for k in keys:
			k2.append([float(k[0]) * s, k[1], k[2], k[3], k[4], k[5]])
		_body(mb, k2, 10, col_fn, 2, off)


static func _wing_col(base: Color, cov: Color, prim: Color, noise := 0.15) -> Callable:
	return func(tt: float, cs: float, sn: float) -> Color:
		var col := base.lerp(cov, _ss(0.1, 0.6, sn) * (1.0 - _ss(0.3, 0.5, tt)))
		col = col.lerp(prim, _ss(0.55, 0.8, tt))
		# feather-row banding
		if fposmod(tt * 7.0 + sn * 0.8, 1.0) < 0.18:
			col = col.darkened(0.15)
		return _vary(col, Vector3(tt * 9.0, cs, sn), noise)


func _build_turkey() -> void:
	var black := Color(0.075, 0.07, 0.065)
	var under := Color(0.24, 0.22, 0.2)
	var red := Color(0.82, 0.14, 0.09)
	var yellow := Color(0.98, 0.8, 0.18)
	var leg := Color(0.45, 0.4, 0.35)
	hip = Vector3(0, 0.36, -0.03)
	tib_len = 0.17
	tar_len = 0.2
	tib_rest = 0.45
	tar_rest = -0.25
	toe_r = 0.014
	body_clear = 0.12
	stand_tilt = -0.08
	neck_world = -1.15
	neck_fly = -0.25
	neck_peck = 1.0
	tail_world = 0.13
	tail_fly = 0.35
	flap_freq = 7.0
	flap_amp = 0.95
	dihedral = 0.05
	stride0 = 0.75
	stride1 = 1.5
	body.position = hip
	var o := hip
	body_mi = _add_mesh(body, "body", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, 0.475, -0.25, 0.05, 0.05, 0.05],
			[0, 0.475, -0.19, 0.11, 0.11, 0.1],
			[0, 0.47, -0.09, 0.145, 0.15, 0.15],
			[0, 0.465, 0.03, 0.15, 0.15, 0.165],
			[0, 0.475, 0.13, 0.13, 0.13, 0.15],
			[0, 0.505, 0.2, 0.09, 0.09, 0.1],
			[0, 0.535, 0.235, 0.05, 0.05, 0.05],
		], 14, func(tt: float, cs: float, sn: float) -> Color:
			var col := black.lerp(under, _ss(-0.4, -0.9, sn) * (1.0 - _ss(0.6, 0.9, tt)))
			if fposmod(tt * 11.0 + cs * 0.5, 1.0) < 0.2 and sn < 0.2:
				col = col.lerp(under, 0.5)     # scalloped grey feather edges
			return _vary(col, Vector3(tt * 9.0, cs, sn), 0.3), 2, o)
		_folded_wings(mb, [
			[0.12, 0.545, 0.14, 0.02, 0.06, 0.07],
			[0.14, 0.52, 0.03, 0.03, 0.1, 0.1],
			[0.125, 0.49, -0.12, 0.025, 0.08, 0.07],
			[0.07, 0.48, -0.23, 0.012, 0.035, 0.03],
		], o, _wing_col(Color(0.1, 0.09, 0.08), Color(0.16, 0.14, 0.12), Color(0.06, 0.055, 0.05), 0.3))
	)
	neck = _node(body, Vector3(0, 0.54, 0.2) - o)
	_add_mesh(neck, "neck", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, 0, -0.04, 0.064, 0.064, 0.064],
			[0, 0, 0.03, 0.05, 0.05, 0.05],
			[0, 0, 0.075, 0.036, 0.036, 0.036],
			[0, 0, 0.15, 0.03, 0.03, 0.03],
			[0, 0, 0.21, 0.028, 0.028, 0.028],
		], 10, func(tt: float, cs: float, sn: float) -> Color:
			var col := black.lerp(red, _ss(0.33, 0.42, tt))
			return _vary(col, Vector3(tt * 9.0, cs, sn), 0.2 if tt < 0.4 else 0.08), 2)
		# pendulous yellow wattle collar at the base of the bare neck
		mb.ellipsoid(Transform3D(Basis(), Vector3(0, -0.038, 0.1)), Vector3(0.042, 0.042, 0.048), yellow, 9, 6, func(d: Vector3) -> Color:
			return _vary(yellow.lerp(Color(1.0, 0.9, 0.4), _ss(0.0, 0.8, d.y)), d, 0.08))
		mb.ellipsoid(Transform3D(Basis(), Vector3(0, -0.05, 0.07)), Vector3(0.03, 0.04, 0.03), yellow, 7, 4)
	)
	head = _node(neck, Vector3(0, 0, 0.21))
	_add_mesh(head, "head", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, 0.0, -0.035, 0.028, 0.03, 0.028],
			[0, 0.004, 0.0, 0.038, 0.042, 0.036],
			[0, 0.004, 0.035, 0.03, 0.032, 0.03],
			[0, -0.002, 0.052, 0.018, 0.02, 0.018],
		], 10, func(tt: float, cs: float, sn: float) -> Color:
			# bare red skin with sparse black bristles on the crown
			var col := red
			if sn > 0.7 and fposmod(cs * 13.0 + tt * 5.0, 1.0) < 0.35:
				col = black
			return _vary(col, Vector3(tt * 9.0, cs, sn), 0.12), 2)
		_body(mb, [
			[0, -0.004, 0.045, 0.016, 0.016, 0.014],
			[0, -0.008, 0.075, 0.011, 0.011, 0.009],
			[0, -0.014, 0.1, 0.004, 0.004, 0.003],
		], 7, _lgrad(Color(0.2, 0.18, 0.16), Color(0.3, 0.27, 0.23)), 2)
		for s in [-1.0, 1.0]:
			mb.ellipsoid(Transform3D(Basis(), Vector3(0.028 * s, 0.012, 0.022)), Vector3.ONE * 0.009, Color(0.45, 0.32, 0.12), 6, 4)
			mb.ellipsoid(Transform3D(Basis(), Vector3(0.034 * s, 0.012, 0.025)), Vector3.ONE * 0.005, Color(0.02, 0.02, 0.02), 4, 3)
	)
	tail = _node(body, Vector3(0, 0.5, -0.21) - o)
	_add_mesh(tail, "tail", func(mb: MeshBuilder) -> void:
		# laterally flattened vertical fan: outline (up, z)
		var p := PackedVector2Array([Vector2(-0.03, 0.04), Vector2(0.07, 0.03), Vector2(0.18, -0.02), Vector2(0.26, -0.09), Vector2(0.28, -0.17), Vector2(0.23, -0.25), Vector2(0.12, -0.28), Vector2(0.02, -0.23), Vector2(-0.05, -0.11)])
		var xf := Transform3D(Basis(Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)), Vector3.ZERO)
		_slab(mb, xf, p, 0.04, black, black, Color(0.13, 0.12, 0.11))
		# feather rachis ridges fanning out on both faces
		for k in 6:
			var a := lerpf(0.25, 1.6, k / 5.0)
			var d := Vector3(0, sin(a), -cos(a))
			for sx in [-1.0, 1.0]:
				mb.tube(Vector3(0.012 * sx, 0.02, -0.02), Vector3(0.018 * sx, 0.02, -0.02) + d * 0.25, 0.012, 0.006, black, Color(0.11, 0.1, 0.09), 4, false)
	)
	_build_wings(Vector3(0.12, 0.545, 0.13) - o, 0.3, 0.26, 0.3, 0.22, 0, 0.0, Color(0.1, 0.09, 0.08), Color(0.18, 0.17, 0.16), 0.03)
	_build_legs(0.07, black, Vector3(0.05, 0.1, 0.06), leg, 0.019, leg, 0.105, Color(0.22, 0.2, 0.18))


func _build_crow() -> void:
	var black := Color(0.035, 0.035, 0.045)
	var sheen := Color(0.11, 0.11, 0.19)
	hip = Vector3(0, 0.2, -0.02)
	tib_len = 0.1
	tar_len = 0.13
	tib_rest = 0.45
	tar_rest = -0.2
	toe_r = 0.011
	body_clear = 0.08
	stand_tilt = -0.32
	neck_world = -0.85
	neck_fly = -0.12
	neck_peck = 0.95
	tail_world = 0.02
	tail_fly = -0.05
	flap_freq = 3.6
	flap_amp = 0.8
	dihedral = 0.08
	tip_up = 0.05
	stride0 = 0.9
	stride1 = 1.8
	body.position = hip
	var o := hip
	var plume := func(tt: float, cs: float, sn: float) -> Color:
		return _vary(black.lerp(sheen, _ss(0.1, 0.9, sn) * 0.8), Vector3(tt * 9.0, cs, sn), 0.25)
	body_mi = _add_mesh(body, "body", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, 0.275, -0.17, 0.04, 0.035, 0.035],
			[0, 0.272, -0.11, 0.08, 0.08, 0.075],
			[0, 0.27, -0.01, 0.1, 0.1, 0.1],
			[0, 0.28, 0.09, 0.095, 0.095, 0.105],
			[0, 0.3, 0.17, 0.072, 0.072, 0.08],
			[0, 0.32, 0.215, 0.045, 0.045, 0.045],
		], 12, plume, 2, o)
		_folded_wings(mb, [
			[0.08, 0.315, 0.13, 0.014, 0.04, 0.05],
			[0.098, 0.295, 0.02, 0.022, 0.075, 0.07],
			[0.08, 0.285, -0.13, 0.018, 0.05, 0.04],
			[0.035, 0.29, -0.3, 0.008, 0.02, 0.012],
		], o, _wing_col(black.lerp(sheen, 0.5), sheen, black, 0.25))
	)
	neck = _node(body, Vector3(0, 0.3, 0.19) - o)
	_add_mesh(neck, "neck", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, -0.005, -0.04, 0.066, 0.066, 0.075],
			[0, 0.0, 0.02, 0.06, 0.06, 0.07],
			[0, 0.0, 0.08, 0.05, 0.05, 0.055],
		], 10, plume, 2)
		# shaggy throat hackles: lanceolate feathers hanging from the throat
		for i in 7:
			var fx := (i - 3) * 0.013
			var zb := 0.01 + (i % 2) * 0.02
			mb.cone(Vector3(fx, -0.045, zb + 0.03), Vector3(fx * 1.3, -0.1 - 0.012 * (i % 3), zb - 0.02), 0.014, black, black.lerp(sheen, 0.3), 4)
	)
	head = _node(neck, Vector3(0, 0, 0.08))
	_add_mesh(head, "head", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, 0.0, -0.05, 0.035, 0.035, 0.035],
			[0, 0.01, -0.02, 0.054, 0.056, 0.05],
			[0, 0.014, 0.025, 0.054, 0.052, 0.048],
			[0, 0.008, 0.06, 0.036, 0.034, 0.034],
		], 10, plume, 2)
		# heavy, arched bill with nasal bristles
		_body(mb, [
			[0, 0.008, 0.045, 0.027, 0.028, 0.024],
			[0, 0.006, 0.09, 0.02, 0.022, 0.018],
			[0, -0.002, 0.135, 0.012, 0.014, 0.011],
			[0, -0.016, 0.17, 0.005, 0.006, 0.004],
			[0, -0.026, 0.182, 0.0015, 0.0015, 0.0015],
		], 8, _lgrad(Color(0.05, 0.05, 0.055), Color(0.02, 0.02, 0.02)), 2)
		mb.ellipsoid(Transform3D(Basis(Vector3.RIGHT, -0.3), Vector3(0, 0.025, 0.07)), Vector3(0.022, 0.012, 0.035), black.lerp(sheen, 0.3), 6, 3)
		for s in [-1.0, 1.0]:
			# Australian ravens have white irises
			mb.ellipsoid(Transform3D(Basis(), Vector3(0.042 * s, 0.02, 0.035)), Vector3.ONE * 0.012, Color(0.92, 0.92, 0.88), 6, 4)
			mb.ellipsoid(Transform3D(Basis(), Vector3(0.049 * s, 0.02, 0.039)), Vector3.ONE * 0.0055, Color(0.01, 0.01, 0.01), 4, 3)
	)
	tail = _node(body, Vector3(0, 0.28, -0.14) - o)
	_add_mesh(tail, "tail", func(mb: MeshBuilder) -> void:
		var p := PackedVector2Array([Vector2(0.035, 0.03), Vector2(0.07, -0.2), Vector2(0.058, -0.245), Vector2(0.03, -0.268), Vector2(0.0, -0.275), Vector2(-0.03, -0.268), Vector2(-0.058, -0.245), Vector2(-0.07, -0.2), Vector2(-0.035, 0.03)])
		_slab(mb, Transform3D(), p, 0.028, black.lerp(sheen, 0.45), black)
		for k in 5:
			var x := (k - 2) * 0.025
			mb.tube(Vector3(x * 0.4, 0.008, 0.0), Vector3(x, 0.008, -0.25 + absf(x) * 0.6), 0.005, 0.003, black.lerp(sheen, 0.6), black, 3, false)
	)
	_build_wings(Vector3(0.075, 0.325, 0.1) - o, 0.46, 0.27, 0.52, 0.24, 5, 0.2, black.lerp(sheen, 0.45), black, 0.02)
	_build_legs(0.05, black, Vector3(0.035, 0.06, 0.04), Color(0.05, 0.05, 0.05), 0.012, Color(0.06, 0.06, 0.06), 0.075, Color(0.02, 0.02, 0.02))


func _build_eagle() -> void:
	var brown := Color(0.22, 0.145, 0.09)
	var dark := Color(0.12, 0.085, 0.055)
	var gold := Color(0.6, 0.42, 0.22)
	var beak := Color(0.87, 0.81, 0.63)
	hip = Vector3(0, 0.3, -0.02)
	tib_len = 0.15
	tar_len = 0.14
	tib_rest = 0.25
	tar_rest = -0.1
	toe_r = 0.014
	body_clear = 0.12
	stand_tilt = -0.72
	neck_world = -1.2
	neck_fly = -0.15
	neck_peck = 0.95
	tail_world = 0.2
	tail_fly = 0.0
	flap_freq = 1.7
	flap_amp = 0.55
	dihedral = 0.13
	tip_up = 0.2
	fold_in_scale = 0.28
	stride0 = 0.8
	stride1 = 1.4
	body.position = hip
	var o := hip
	var plume := func(tt: float, cs: float, sn: float) -> Color:
		var col := brown.lerp(dark, _ss(0.0, -0.8, sn) * 0.5)
		col = col.lerp(gold, _ss(0.6, 0.95, sn) * _ss(0.6, 0.95, tt) * 0.8)
		return _vary(col, Vector3(tt * 9.0, cs, sn), 0.28)
	body_mi = _add_mesh(body, "body", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, 0.4, -0.25, 0.05, 0.045, 0.045],
			[0, 0.4, -0.17, 0.105, 0.105, 0.1],
			[0, 0.4, -0.05, 0.135, 0.14, 0.14],
			[0, 0.41, 0.08, 0.13, 0.14, 0.145],
			[0, 0.43, 0.2, 0.1, 0.105, 0.115],
			[0, 0.45, 0.275, 0.065, 0.065, 0.07],
		], 14, plume, 2, o)
		_folded_wings(mb, [
			[0.115, 0.495, 0.19, 0.02, 0.07, 0.08],
			[0.14, 0.455, 0.03, 0.032, 0.125, 0.11],
			[0.1, 0.415, -0.2, 0.025, 0.08, 0.06],
			[0.045, 0.405, -0.44, 0.01, 0.03, 0.015],
		], o, _wing_col(brown, gold.darkened(0.15), dark, 0.25))
	)
	neck = _node(body, Vector3(0, 0.44, 0.26) - o)
	_add_mesh(neck, "neck", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, -0.005, -0.06, 0.085, 0.085, 0.09],
			[0, 0.0, 0.0, 0.078, 0.08, 0.085],
			[0, 0.0, 0.07, 0.066, 0.068, 0.07],
		], 12, func(tt: float, cs: float, sn: float) -> Color:
			# golden-brown hackles on the nape
			return _vary(brown.lerp(gold, _ss(-0.2, 0.7, sn) * 0.9), Vector3(tt * 9.0, cs, sn), 0.3), 2)
	)
	head = _node(neck, Vector3(0, 0, 0.08))
	_add_mesh(head, "head", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, 0.0, -0.06, 0.04, 0.04, 0.04],
			[0, 0.012, -0.03, 0.062, 0.062, 0.058],
			[0, 0.016, 0.015, 0.066, 0.062, 0.058],
			[0, 0.012, 0.055, 0.05, 0.045, 0.045],
			[0, 0.01, 0.075, 0.035, 0.035, 0.035],
		], 12, func(tt: float, cs: float, sn: float) -> Color:
			var col := brown.lerp(gold, _ss(0.0, 0.8, sn) * _ss(0.55, 0.1, tt))
			return _vary(col, Vector3(tt * 9.0, cs, sn), 0.2), 2)
		# heavy brow ridges shading the eyes
		for s in [-1.0, 1.0]:
			mb.ellipsoid(Transform3D(Basis(Vector3.UP, 0.3 * s), Vector3(0.04 * s, 0.038, 0.05)), Vector3(0.026, 0.012, 0.034), dark, 7, 4)
			mb.ellipsoid(Transform3D(Basis(), Vector3(0.047 * s, 0.022, 0.048)), Vector3.ONE * 0.013, Color(0.4, 0.26, 0.1), 6, 4)
			mb.ellipsoid(Transform3D(Basis(), Vector3(0.053 * s, 0.022, 0.052)), Vector3.ONE * 0.006, Color(0.02, 0.015, 0.01), 4, 3)
		# cere + massive hooked pale beak
		_body(mb, [
			[0, 0.014, 0.06, 0.032, 0.03, 0.03],
			[0, 0.016, 0.09, 0.026, 0.026, 0.026],
			[0, 0.012, 0.12, 0.021, 0.024, 0.02],
			[0, 0.0, 0.145, 0.015, 0.02, 0.012],
			[0, -0.022, 0.162, 0.009, 0.012, 0.007],
			[0, -0.046, 0.158, 0.002, 0.002, 0.002],
		], 9, func(tt: float, cs: float, sn: float) -> Color:
			var col := Color(0.88, 0.78, 0.5).lerp(beak, _ss(0.1, 0.25, tt))
			col = col.lerp(Color(0.3, 0.27, 0.22), _ss(0.72, 0.95, tt))
			return col, 2)
		mb.ellipsoid(Transform3D(Basis(), Vector3(0, -0.008, 0.1)), Vector3(0.02, 0.012, 0.035), beak.darkened(0.1), 6, 3)
	)
	tail = _node(body, Vector3(0, 0.38, -0.2) - o)
	_add_mesh(tail, "tail", func(mb: MeshBuilder) -> void:
		# long diamond / wedge tail
		var p := PackedVector2Array([Vector2(0.05, 0.03), Vector2(0.12, -0.18), Vector2(0.07, -0.33), Vector2(0.0, -0.46), Vector2(-0.07, -0.33), Vector2(-0.12, -0.18), Vector2(-0.05, 0.03)])
		_slab(mb, Transform3D(), p, 0.022, brown, dark.lerp(gold, 0.15))
		for k in 7:
			var x := (k - 3) * 0.032
			mb.tube(Vector3(x * 0.3, 0.011, 0.0), Vector3(x * 0.9, 0.011, -0.43 + absf(x) * 1.6), 0.006, 0.003, brown.darkened(0.25), dark, 3, false)
	)
	_build_wings(Vector3(0.1, 0.47, 0.12) - o, 0.52, 0.36, 0.54, 0.33, 7, 0.28, brown, dark.lerp(gold, 0.2), 0.026)
	_build_legs(0.075, brown, Vector3(0.065, 0.11, 0.07), brown, 0.026, Color(0.9, 0.78, 0.3), 0.075, Color(0.05, 0.04, 0.03))


# ================================================================ update

func update_rig(dt: float) -> void:
	if c == null or dt <= 0.0:
		return
	dt = minf(dt, 0.1)
	t += dt
	var L := maxf(c.length, 0.001)
	var ws := maxf(0.01, c.walk_speed())
	var rs := maxf(ws + 0.01, c.run_speed())
	var flying := c.flying and not dead
	var spd := 0.0 if dead or flying else c.speed
	move_w = lerpf(move_w, clampf(spd / (ws * 0.6), 0.0, 1.0), 1.0 - exp(-8.0 * dt))
	run_w = lerpf(run_w, clampf((spd - ws) / (rs - ws), 0.0, 1.0), 1.0 - exp(-5.0 * dt))
	var eating := c.action == "eat" or c.action == "drink"
	eat_w = move_toward(eat_w, 1.0 if eating and not dead and not flying else 0.0, dt * 3.5)
	var rest_a := c.rest_amt if not (dead or flying) else 0.0
	if dead:
		dead_amt = move_toward(dead_amt, 1.0, dt * 2.5)
	# ---- vertical speed & yaw rate
	var y := c.position.y
	var vy_now := (y - _prev_y) / dt
	_prev_y = y
	if absf(vy_now) > 30.0:
		vy_now = 0.0
	vy = lerpf(vy, vy_now, 1.0 - exp(-4.0 * dt))
	var yr := wrapf(c.yaw - _prev_yaw, -PI, PI) / dt
	_prev_yaw = c.yaw
	# ---- gait phase
	var dg := c.gait_phase - _last_gp
	_last_gp = c.gait_phase
	if dg < 0.0 or dg > 4.0 or flying:
		dg = 0.0
	var cyc := lerpf(stride0, stride1, run_w)
	phase = fposmod(phase + dg * c.stride() / L / cyc, 1.0)
	hop_w = lerpf(hop_w, 1.0 if kind == "crow" and run_w > 0.15 else 0.0, 1.0 - exp(-6.0 * dt))
	# ---- wings open / fold (~0.3 s transitions)
	var open_t := 0.0
	if flying:
		open_t = 1.0
	elif kind == "turkey" and run_w > 0.6 and not dead:
		open_t = 0.6          # flap-running
	open = move_toward(open, open_t, dt / 0.3)
	fly_w = move_toward(fly_w, 1.0 if flying else 0.0, dt / 0.3)
	# ---- flapping
	var flap_t := 0.0
	if open_t > 0.0 and not dead:
		match kind:
			"eagle":
				flap_t = 1.0 if (vy > 0.35 or open < 0.95 or c.speed < 3.0) else 0.0
			"crow":
				glide_timer -= dt
				if glide_timer <= -2.5:
					glide_timer = randf_range(1.0, 3.0)
				flap_t = 0.15 if (vy < -0.4 or glide_timer < 0.0) and open > 0.95 else 1.0
			_:
				flap_t = 1.0
	flap_amt = lerpf(flap_amt, flap_t, 1.0 - exp(-3.0 * dt))
	var freq := flap_freq * (1.25 if open < 0.95 else 1.0)
	flap_ph += dt * TAU * freq * lerpf(0.4, 1.0, flap_amt)
	if flap_amt < 0.05:
		flap_ph = lerpf(flap_ph, round(flap_ph / PI) * PI, 1.0 - exp(-3.0 * dt))
	var fa := flap_amp * flap_amt
	var flap := sin(flap_ph) * fa
	var upstroke := maxf(0.0, cos(flap_ph)) * flap_amt
	# ---- terrain pitch (ground only)
	var f := c.fwd()
	var tp := 0.0
	if not dead and fly_w < 1.0:
		var hf := c.terrain.height(c.position.x + f.x * L * 0.3, c.position.z + f.z * L * 0.3)
		var hb := c.terrain.height(c.position.x - f.x * L * 0.3, c.position.z - f.z * L * 0.3)
		tp = -atan2(hf - hb, L * 0.6) * (1.0 - fly_w)
	t_pitch = lerpf(t_pitch, clampf(tp, -0.5, 0.5), 1.0 - exp(-6.0 * dt))
	# ---- look
	look_timer -= dt
	if look_timer <= 0.0:
		look_timer = randf_range(0.6, 2.5) if kind != "eagle" else randf_range(1.5, 4.0)
		look_goal = randf_range(-1.0, 1.0) if move_w < 0.3 else randf_range(-0.2, 0.2)
		look_roll = randf_range(-0.35, 0.35) if kind == "crow" and randf() < 0.4 else 0.0
	var ty := look_goal * (1.0 - fly_w * 0.7)
	if c.brain != null and c.brain.get("look_point") is Vector3:
		var lp: Vector3 = c.brain.get("look_point")
		var dl := lp - c.position
		ty = clampf(wrapf(atan2(dl.x, dl.z) - c.yaw, -PI, PI), -1.3, 1.3)
	if eating or dead:
		ty = 0.0
	var snap := 10.0 if kind != "eagle" else 4.0   # birds snap their head around
	head_yaw = lerpf(head_yaw, ty, 1.0 - exp(-snap * dt))
	head_roll = lerpf(head_roll, look_roll if not eating else 0.0, 1.0 - exp(-6.0 * dt))
	# ---- bite / peck strike
	var lunge := 0.0
	if bite_t >= 0.0:
		bite_t += dt
		var bk := bite_t / maxf(0.2, c.action_len if c.action_len > 0.0 else 0.45)
		lunge = sin(clampf(bk / 0.6, 0.0, 1.0) * PI)
		if bk >= 1.0:
			bite_t = -1.0
	hit_t = maxf(0.0, hit_t - dt)
	# ================= legs
	var duty := lerpf(0.62, 0.45, run_w)
	var amp := asin(clampf(duty * cyc / (2.0 * hip.y), 0.0, 0.6)) * move_w
	var angs := []
	var low := 0.0
	var hop_y := 0.0
	for k in 2:
		var off := 0.5 * k * (1.0 - hop_w)
		var q := fposmod(phase + off, 1.0)
		var s: float
		var lift := 0.0
		if q < duty:
			s = lerpf(-1.0, 1.0, q / duty)
		else:
			var w := (q - duty) / (1.0 - duty)
			s = cos(w * PI)
			lift = sin(w * PI) * move_w
			if k == 0:
				hop_y = sin(w * PI) * hop_w * 0.12 * move_w
		var a0 := tib_rest + s * amp * 0.6 - lift * 0.35
		var a1 := tar_rest + s * amp + lift * 0.9
		var ft := lift * 0.9
		# sitting
		if rest_a > 0.0:
			var ra := _ss(0.0, 0.8, rest_a)
			a0 = lerpf(a0, -1.25, ra)
			a1 = lerpf(a1, 1.45, ra)
			ft = lerpf(ft, -1.45 + 1.45, ra)
		# pecking crouch
		if eat_w > 0.0:
			a0 -= 0.25 * eat_w
			a1 += 0.2 * eat_w
		# flight tuck: legs trail back, toes curled
		if fly_w > 0.0:
			var tk := fly_w
			a0 = lerpf(a0, 1.1 if kind != "eagle" else 0.9, tk)
			a1 = lerpf(a1, 2.0 if kind != "eagle" else 1.7, tk)
			ft = lerpf(ft, 1.3, tk)
		if dead_amt > 0.0:
			a0 = lerpf(a0, 0.5 + 0.2 * k, dead_amt)
			a1 = lerpf(a1, 0.4 + 0.2 * k, dead_amt)
			ft = lerpf(ft, 1.2, dead_amt)
		angs.append(Vector3(a0, a1, ft))
		var lo := -(tib_len * cos(a0) + tar_len * cos(a1)) - toe_r
		if k == 0 or lo < low:
			low = lo
	var y_ground := -(hip.y + low)
	y_ground = maxf(y_ground, -(hip.y - body_clear)) if rest_a > 0.0 else y_ground
	var y_off := lerpf(y_ground + hop_y, 0.0, fly_w)
	y_off = lerpf(y_off, 0.0, dead_amt)
	for k in 2:
		var a: Vector3 = angs[k]
		legs[k].rotation = Vector3(a.x, 0.0, (0.15 if k == 0 else -0.15) * dead_amt)
		ankles[k].rotation = Vector3(a.y - a.x, 0.0, 0.0)
		feet[k].rotation = Vector3(a.z - a.y, 0.0, 0.0)
	# ================= body tilt
	var tl := stand_tilt
	tl = lerpf(tl, stand_tilt * 0.5 + 0.12, run_w)
	tl = lerpf(tl, 0.35 if kind != "eagle" else -0.1, eat_w)
	tl = lerpf(tl, clampf(-vy * 0.06, -0.35, 0.3), fly_w)
	tl = lerpf(tl, 0.0 if kind != "eagle" else -0.35, _ss(0.0, 1.0, rest_a))
	tl = lerpf(tl, 0.0, dead_amt)
	tl += sin(phase * TAU * 2.0) * 0.03 * move_w
	tilt = lerpf(tilt, tl, 1.0 - exp(-7.0 * dt))
	body.rotation = Vector3(tilt, 0.0, 0.0)
	if body_mi != null:
		var br := 1.0 + sin(t * 3.0) * 0.012 * (1.0 - dead_amt)
		body_mi.scale = Vector3(br, br, 1.0)
	# ================= neck & head
	var nw := neck_world
	var hw := 0.0
	nw += sin(phase * TAU * 2.0) * 0.14 * move_w * (1.0 - hop_w)     # walking head bob
	nw = lerpf(nw, neck_fly, fly_w)
	if eat_w > 0.0:
		var peck := 0.0
		if c.action == "eat":
			var pr := 7.0 if kind != "eagle" else 3.0
			peck = pow(maxf(0.0, sin(c.action_t * pr)), 2.0)
			nw = lerpf(nw, neck_peck + 0.3 * peck - 0.2, eat_w)
			hw = lerpf(hw, 1.1 + 0.3 * peck, eat_w)
		else:
			# drink: dip, then tilt the head back to swallow
			var cyc_d := fposmod(c.action_t, 2.0)
			var dip := _ss(0.0, 0.3, cyc_d) * (1.0 - _ss(0.9, 1.3, cyc_d))
			nw = lerpf(nw, lerpf(neck_world + 0.2, neck_peck + 0.1, dip), eat_w)
			hw = lerpf(hw, lerpf(-0.5, 1.2, dip), eat_w)
	nw = lerpf(nw, nw + 0.5, _ss(0.3, 1.0, rest_a) * (0.0 if kind == "eagle" else 1.0))
	if lunge > 0.0:
		nw = lerpf(nw, neck_peck * 0.6, lunge)
		hw = lerpf(hw, 0.6, lunge)
	if dead_amt > 0.0:
		nw = lerpf(nw, 0.6, dead_amt)
		hw = lerpf(hw, 0.6, dead_amt)
	neck.rotation = Vector3(nw - tilt, head_yaw * 0.4, 0.0)
	head.rotation = Vector3(hw - nw, head_yaw * 0.6, head_roll)
	# ================= tail
	var tw := lerpf(tail_world, tail_fly, fly_w)
	var tail_rx := tw
	if kind == "crow":
		tail_rx += maxf(0.0, sin(t * 1.7)) * 0.15 * (1.0 - fly_w) * (1.0 - move_w)
	if kind == "eagle":
		tail_rx += clampf(vy * 0.03, -0.15, 0.15) * fly_w
	if dead_amt > 0.0:
		tail_rx = lerpf(tail_rx, 0.0, dead_amt)
	tail.rotation = Vector3(tail_rx, 0.0, clampf(-yr * 0.15, -0.4, 0.4) * fly_w)
	var spread := 1.0 + 0.35 * fly_w * (1.0 - flap_amt * 0.5) if kind != "turkey" else 1.0
	tail.scale = Vector3(spread, 1.0, 1.0)
	# ================= wings
	# Folded wings are baked into the body mesh; the flight wings unfold out of
	# them (orientation slerp + growing scale) and are hidden when fully folded.
	var soar := sin(t * 0.7) * 0.06 * (1.0 - flap_amt) if kind == "eagle" else 0.0
	for i in 2:
		var s := 1.0 if i == 0 else -1.0
		var ow := open
		var dih := dihedral + (soar * s if kind == "eagle" else 0.0)
		var fl := flap
		if open < 0.99 and open_t < 1.0 and not dead:
			fl *= 0.8
		var sweep := 0.08 + upstroke * 0.25
		var hand_flap := sin(flap_ph - 0.6) * fa * 0.55 + tip_up * (1.0 - flap_amt)
		if dead:
			# on its side: upper wing stays folded, lower wing lies limp on the ground
			ow = 0.0 if i == 0 else 0.75 * dead_amt
			fl = 1.35
			dih = 0.0
			sweep = 0.35
			hand_flap = -0.25
		wings[i].visible = ow > 0.02
		if not wings[i].visible:
			continue
		var twist := -0.18 * cos(flap_ph) * flap_amt
		var sp := Basis.from_euler(Vector3(twist, s * sweep, s * (dih + fl)))
		var q := fold_q[i].slerp(sp.get_rotation_quaternion(), _ss(0.0, 1.0, ow))
		wings[i].basis = Basis(q).scaled(Vector3.ONE * lerpf(0.45, 1.0, _ss(0.0, 0.7, ow)))
		var sc := lerpf(fold_in_scale, 1.0 - upstroke * 0.15, ow)
		wing_inner[i].scale = Vector3(sc, 1.0, 1.0)
		wrists[i].position = Vector3(span_in * sc * s, 0.0, 0.0)
		var hand_sweep := upstroke * 0.5 + 0.05
		var hb := Basis.from_euler(Vector3(0.0, s * hand_sweep, s * hand_flap))
		var fold_hand := Basis.from_euler(Vector3(0.0, s * 0.05, s * 0.06))
		wrists[i].quaternion = fold_hand.get_rotation_quaternion().slerp(hb.get_rotation_quaternion(), ow)
	# ================= root: bank, death roll, jolt
	var bank_t := clampf(-yr * 0.35, -0.7, 0.7) * fly_w
	if kind == "eagle":
		bank_t += sin(t * 0.45) * 0.07 * fly_w * (1.0 - flap_amt)
	bank = lerpf(bank, bank_t, 1.0 - exp(-3.0 * dt))
	var jolt := sin(hit_t * 45.0) * hit_t * 0.35 + c.flinch * 0.1
	var roll := _ss(0.0, 1.0, dead_amt) * PI * 0.5
	var bh := hip.y + 0.08
	root.position = Vector3(bh * sin(roll), lerpf(y_off, 0.12, sin(roll)) + (sin(flap_ph) * 0.02 * flap_amt * fly_w), -jolt * 0.1)
	root.rotation = Vector3(t_pitch * (1.0 - dead_amt) - jolt * 0.4, 0.0, bank + roll + jolt * 0.3)
