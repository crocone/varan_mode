class_name MammalRig
extends Node3D
## Procedural quadruped rig made of rigid vertex-coloured parts hung on joint
## pivots (FK). Species: dingo (walk / trot / gallop), wallaby and hopping
## mouse (bipedal hop). Meshes are built once per species in normalised units
## (creature length = 1) and shared between instances; the rig node itself is
## scaled by creature.length. Local +Z is forward, +Y up, +X is the left side.
##
## Leg angles are "absolute" pitch angles in the root frame, measured from
## straight down; positive swings the foot backward (-Z).

static var _cache := {}
static var _mat: StandardMaterial3D = null

const EYE := Color(0.06, 0.045, 0.03)
const NOSE := Color(0.08, 0.065, 0.06)

var c: Creature
var hop := false
var root := Node3D.new()        # whole-body offset, terrain pitch, death roll
var torso := Node3D.new()       # pivot at the hips; body lean
var body_mi: MeshInstance3D
var neck: Node3D
var head: Node3D
var jaw: Node3D
var ears: Array[Node3D] = []
var tails: Array[Node3D] = []
var tail_rest := PackedFloat32Array()
var legs: Array = []            # per leg: Array of joint pivots (top first)
var leg_rest: Array = []        # per leg: PackedFloat32Array abs angles
var leg_len: Array = []         # per leg: PackedFloat32Array segment lengths
var leg_lie: Array = []         # per leg: resting pose
var leg_dead: Array = []        # per leg: dead pose
var leg_front: Array[bool] = []
var leg_hip_y := PackedFloat32Array()
var arms: Array = []            # hopper forelegs (relative to torso)
var neck_base := Vector3.ZERO

# species shape parameters (normalised units)
var hip_y := 0.47
var torso_h := 0.47
var half_w := 0.11
var lie_drop := 0.3
var pad := 0.018
var neck_rest := -0.75
var neck_run := -0.35
var neck_eat := 0.75
var head_eat := 1.05
var stride0 := 0.7
var stride1 := 3.6
var leg_h := 0.45
var hop_f0 := 2.2
var hop_f1 := 3.0
var hop_min := 0.5
var hop_h := 0.3
var run_lean := 0.45
var ear_tilt := 0.25
var hop_rest := Vector3(-0.9, 0.75, -1.52)
var hop_crouch := Vector3(-1.3, 1.35, -1.55)
var arm_rest := Vector2(-0.5, -1.2)

# animation state
var phase := 0.0
var _last_gp := 0.0
var t := 0.0
var move_w := 0.0
var run_w := 0.0
var eat_w := 0.0
var t_pitch := 0.0
var lean := 0.0
var head_yaw := 0.0
var head_pitch := 0.0
var look_timer := 1.0
var look_goal := 0.0
var look_goal_p := 0.0
var ear_timer := 2.0
var ear_side := 0
var ear_t := 0.0
var bite_t := -1.0
var hit_t := 0.0
var dead := false
var dead_amt := 0.0
var y_off := 0.0
var leg_pitch := 0.0


func setup(creature: Creature) -> void:
	c = creature
	hop = c.sp.get("gait", "trot") == "hop"
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true
		_mat.vertex_color_is_srgb = true
		_mat.roughness = 0.85
	add_child(root)
	root.add_child(torso)
	match c.species_id:
		"wallaby":
			_build_hopper(false)
		"mouse":
			_build_hopper(true)
		_:
			_build_dingo()
	on_resize()
	_last_gp = c.gait_phase
	phase = randf()
	look_timer = randf_range(0.3, 3.0)
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


static func _vary(col: Color, d: Vector3, amt := 0.08) -> Color:
	var k := 1.0 + (_hash3(d) - 0.5) * amt
	return Color(col.r * k, col.g * k, col.b * k)


## Ellipsoid colouring: top colour fading to belly colour below `thr` (unit-dir y).
static func _fur(top: Color, belly: Color, thr := -0.35, back := Color(-1, 0, 0)) -> Callable:
	return func(d: Vector3) -> Color:
		var col := top
		if back.r >= 0.0:
			col = col.lerp(back, _ss(0.45, 0.85, d.y))
		col = col.lerp(belly, _ss(thr, thr - 0.3, d.y))
		return _vary(col, d)


## Loft colouring (t along, cs side, sn up): top / dorsal stripe / belly.
static func _lfur(top: Color, belly: Color, thr := -0.35, back := Color(-1, 0, 0)) -> Callable:
	return func(tt: float, cs: float, sn: float) -> Color:
		var col := top
		if back.r >= 0.0:
			col = col.lerp(back, _ss(0.5, 0.95, sn))
		col = col.lerp(belly, _ss(thr, thr - 0.35, sn))
		return _vary(col, Vector3(tt * 7.0, cs, sn), 0.07)


## Loft colouring by position along the loft only.
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


## Smooth lofted tube: elliptical rings (half-width, half-height up, half-height
## down) along a Catmull-Rom path. col_fn(t, cs, sn) -> Color.
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


## Limb segment lofted down -Y. keys: [f (0..1 along), half_width, front, back].
static func _limb(mb: MeshBuilder, length: float, keys: Array, sides: int, col_fn: Callable, sub := 1) -> void:
	var pts := PackedVector3Array()
	var sz := PackedVector3Array()
	for k in keys:
		pts.append(Vector3(0, -float(k[0]) * length, 0))
		sz.append(Vector3(k[1], k[2], k[3]))
	_loft(mb, pts, sz, Vector3(0, 0, 1), sides, col_fn, sub)


## Loft from key arrays [x, y, z, half_w, up, down] along a mostly-horizontal path.
static func _body(mb: MeshBuilder, keys: Array, sides: int, col_fn: Callable, sub := 2, off := Vector3.ZERO, caps := true) -> void:
	var pts := PackedVector3Array()
	var sz := PackedVector3Array()
	for k in keys:
		pts.append(Vector3(k[0], k[1], k[2]) - off)
		sz.append(Vector3(k[3], k[4], k[5]))
	_loft(mb, pts, sz, Vector3.UP, sides, col_fn, sub, caps)


static func _otri(mb: MeshBuilder, a: Vector3, b: Vector3, cc: Vector3, col: Color, want: Vector3) -> void:
	if (b - a).cross(cc - a).dot(want) < 0.0:
		mb.tri(a, cc, b, col, col, col)
	else:
		mb.tri(a, b, cc, col, col, col)


## Pointed, slightly cupped ear. Base centred at origin, tip at `tip`; the front (+Z) face is `inner`.
static func _ear(mb: MeshBuilder, w: float, dpt: float, tip: Vector3, outer: Color, inner: Color) -> void:
	var bl := Vector3(-w, 0, 0)
	var br := Vector3(w, 0, 0)
	var bk := Vector3(0, 0, -dpt)
	var mid_l := Vector3(-w * 0.62, tip.y * 0.5, -dpt * 0.3) + Vector3(tip.x, 0, tip.z) * 0.5
	var mid_r := Vector3(w * 0.62, tip.y * 0.5, -dpt * 0.3) + Vector3(tip.x, 0, tip.z) * 0.5
	var mid_b := Vector3(0, tip.y * 0.5, -dpt * 0.9) + Vector3(tip.x, 0, tip.z) * 0.5
	var cup := Vector3(0, tip.y * 0.35, dpt * 0.2) + Vector3(tip.x, 0, tip.z) * 0.35
	var cen := Vector3(tip.x * 0.4, tip.y * 0.35, -dpt * 0.5)
	# inner (front) cupped face
	for tr in [[bl, br, cup], [bl, cup, mid_l], [br, mid_r, cup], [mid_l, cup, tip], [cup, mid_r, tip]]:
		_otri(mb, tr[0], tr[1], tr[2], inner, Vector3(0, 0, 1))
	# outer back faces
	for tr in [[bl, mid_l, mid_b], [bl, mid_b, bk], [br, bk, mid_b], [br, mid_b, mid_r], [mid_l, tip, mid_b], [mid_r, mid_b, tip]]:
		var a: Vector3 = tr[0]
		var b: Vector3 = tr[1]
		var cc: Vector3 = tr[2]
		_otri(mb, a, b, cc, outer, (a + b + cc) / 3.0 - cen)
	_otri(mb, bl, bk, br, outer, Vector3.DOWN)


## Paw / foot at the end of a segment, levelled for the segment's rest angle.
static func _paw(mb: MeshBuilder, length: float, rest_abs: float, radii: Vector3, col: Color, fwd := 0.45) -> void:
	var b := Basis(Vector3.RIGHT, -rest_abs)
	var fwd_l := b * Vector3(0, 0, 1)
	var up_l := b * Vector3(0, 1, 0)
	var cen := Vector3(0, -length, 0) + fwd_l * radii.z * fwd + up_l * radii.y * 0.05
	mb.ellipsoid(Transform3D(b, cen), radii, col, 7, 4, _fur(col, col.darkened(0.12), -0.3))
	# toes
	for s in [-1.5, -0.5, 0.5, 1.5]:
		var tc: Vector3 = cen + fwd_l * radii.z * 0.8 + b * Vector3(s * radii.x * 0.42, -radii.y * 0.25, 0)
		mb.ellipsoid(Transform3D(b, tc), Vector3(radii.x * 0.3, radii.y * 0.6, radii.z * 0.35), col, 4, 3)


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
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mi)
	return mi


## Builds a leg as a chain of pivots. builders[i] builds segment i in its own frame.
func _leg(parent: Node3D, key: String, pos: Vector3, lens: PackedFloat32Array, rest: PackedFloat32Array, builders: Array, front: bool) -> void:
	var nodes: Array[Node3D] = []
	var par := parent
	for i in lens.size():
		var n := _node(par, pos if i == 0 else Vector3(0, -lens[i - 1], 0))
		_add_mesh(n, key + str(i), builders[i])
		nodes.append(n)
		par = n
	legs.append(nodes)
	leg_rest.append(rest)
	leg_len.append(lens)
	leg_front.append(front)
	leg_hip_y.append(pos.y)


# ================================================================ dingo

func _build_dingo() -> void:
	hop = false
	var ginger := Color(0.8, 0.5, 0.22)
	var saddle := Color(0.6, 0.35, 0.15)
	var cream := Color(0.95, 0.88, 0.72)
	var pink := Color(0.55, 0.28, 0.26)
	hip_y = 0.47
	torso_h = 0.48
	half_w = 0.1
	lie_drop = 0.31
	neck_rest = -0.8
	neck_run = -0.3
	neck_eat = 1.0
	head_eat = 0.9
	stride0 = 0.75
	stride1 = 3.8
	leg_h = 0.45
	torso.position = Vector3(0, 0.47, -0.24)
	var o := torso.position
	var body_col := func(tt: float, cs: float, sn: float) -> Color:
		var col := ginger.lerp(saddle, _ss(0.55, 0.95, sn) * 0.85)
		var belly_thr := -0.35 if tt < 0.55 else -0.1
		col = col.lerp(cream, _ss(belly_thr, belly_thr - 0.3, sn))
		# cream chest / throat front
		col = col.lerp(cream, _ss(0.84, 0.97, tt) * _ss(0.0, -0.5, sn))
		return _vary(col, Vector3(tt * 9.0, cs, sn), 0.07)
	body_mi = _add_mesh(torso, "body", func(mb: MeshBuilder) -> void:
		# rump -> chest: deep chest, tucked waist
		_body(mb, [
			[0, 0.5, -0.37, 0.03, 0.03, 0.03],
			[0, 0.505, -0.33, 0.07, 0.065, 0.075],
			[0, 0.5, -0.27, 0.092, 0.08, 0.1],
			[0, 0.5, -0.19, 0.094, 0.08, 0.095],
			[0, 0.505, -0.1, 0.086, 0.075, 0.072],
			[0, 0.505, -0.02, 0.092, 0.08, 0.09],
			[0, 0.5, 0.06, 0.1, 0.085, 0.125],
			[0, 0.5, 0.14, 0.102, 0.09, 0.15],
			[0, 0.51, 0.21, 0.094, 0.095, 0.13],
			[0, 0.525, 0.27, 0.078, 0.085, 0.1],
			[0, 0.545, 0.31, 0.05, 0.055, 0.06],
		], 14, body_col, 2, o)
	)
	# neck & head
	neck = _node(torso, Vector3(0, 0.56, 0.25) - o)
	neck_base = neck.position
	_add_mesh(neck, "neck", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, -0.01, -0.08, 0.074, 0.075, 0.09],
			[0, 0.0, 0.0, 0.066, 0.065, 0.078],
			[0, 0.0, 0.08, 0.056, 0.055, 0.062],
			[0, 0.0, 0.15, 0.05, 0.05, 0.055],
		], 12, func(tt: float, cs: float, sn: float) -> Color:
			var col := ginger.lerp(saddle, _ss(0.6, 1.0, sn) * 0.6)
			col = col.lerp(cream, _ss(-0.2, -0.55, sn))
			return _vary(col, Vector3(tt * 9.0, cs, sn), 0.07), 2)
	)
	head = _node(neck, Vector3(0, 0.0, 0.15))
	_add_mesh(head, "head", func(mb: MeshBuilder) -> void:
		# wedge head with defined stop
		_body(mb, [
			[0, 0.02, -0.05, 0.03, 0.03, 0.03],
			[0, 0.024, -0.025, 0.056, 0.055, 0.05],
			[0, 0.026, 0.015, 0.068, 0.058, 0.052],
			[0, 0.022, 0.055, 0.058, 0.05, 0.05],
			[0, 0.008, 0.085, 0.043, 0.036, 0.044],
			[0, 0.0, 0.12, 0.035, 0.03, 0.034],
			[0, -0.003, 0.155, 0.029, 0.026, 0.027],
			[0, -0.004, 0.182, 0.021, 0.02, 0.019],
		], 12, func(tt: float, cs: float, sn: float) -> Color:
			var col := ginger.lerp(saddle, _ss(0.6, 1.0, sn) * 0.5 * (1.0 - tt))
			# cream cheeks and muzzle sides / chin
			var muz := _ss(0.4, 0.6, tt)
			col = col.lerp(cream, _ss(0.1, -0.3, sn) * (0.6 + 0.4 * muz))
			col = col.lerp(cream, muz * _ss(0.75, 0.2, sn) * 0.75)
			# darker muzzle top toward the nose
			col = col.lerp(saddle, _ss(0.8, 1.0, tt) * _ss(0.3, 0.9, sn) * 0.5)
			return _vary(col, Vector3(tt * 9.0, cs, sn), 0.06), 2)
		mb.ellipsoid(Transform3D(Basis(), Vector3(0, 0.003, 0.19)), Vector3(0.019, 0.016, 0.013), NOSE, 7, 4)
		for s in [-1.0, 1.0]:
			# almond eyes set obliquely + brow
			var eb := Basis(Vector3.UP, 0.5 * s) * Basis(Vector3.BACK, -0.3 * s)
			mb.ellipsoid(Transform3D(eb, Vector3(0.043 * s, 0.037, 0.066)), Vector3(0.013, 0.008, 0.01), EYE, 7, 4)
			mb.ellipsoid(Transform3D(eb, Vector3(0.04 * s, 0.047, 0.062)), Vector3(0.02, 0.008, 0.014), saddle, 6, 3)
	)
	jaw = _node(head, Vector3(0, -0.032, 0.05))
	_add_mesh(jaw, "jaw", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, 0.0, -0.02, 0.03, 0.012, 0.018],
			[0, -0.002, 0.04, 0.028, 0.012, 0.018],
			[0, -0.002, 0.1, 0.021, 0.01, 0.014],
			[0, 0.0, 0.132, 0.014, 0.008, 0.009],
		], 10, func(tt: float, cs: float, sn: float) -> Color:
			return pink if sn > 0.75 else _vary(cream, Vector3(tt, cs, sn), 0.05), 2)
	)
	for s in [1.0, -1.0]:
		var e := _node(head, Vector3(0.042 * s, 0.066, 0.005))
		_add_mesh(e, "ear" + ("L" if s > 0 else "R"), func(mb: MeshBuilder) -> void:
			_ear(mb, 0.037, 0.016, Vector3(0.008 * s, 0.1, -0.01), ginger, Color(0.93, 0.8, 0.66))
		)
		ears.append(e)
	ear_tilt = 0.2
	# bushy tail, white tip
	var tb := _node(torso, Vector3(0, 0.505, -0.35) - o)
	_add_mesh(tb, "tail0", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, 0, 0.02, 0.028, 0.03, 0.03],
			[0, 0, -0.06, 0.036, 0.04, 0.04],
			[0, 0, -0.14, 0.044, 0.048, 0.048],
			[0, 0, -0.2, 0.048, 0.05, 0.052],
		], 10, func(tt: float, cs: float, sn: float) -> Color:
			var col := ginger.lerp(saddle, _ss(0.3, 0.9, sn) * 0.8)
			col = col.lerp(cream, _ss(-0.4, -0.8, sn) * 0.6)
			return _vary(col, Vector3(tt * 6.0, cs, sn), 0.08), 1, Vector3.ZERO, false)
	)
	var t2 := _node(tb, Vector3(0, 0, -0.19))
	_add_mesh(t2, "tail1", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, 0, 0.02, 0.048, 0.05, 0.052],
			[0, 0, -0.06, 0.054, 0.056, 0.056],
			[0, 0, -0.14, 0.05, 0.05, 0.05],
			[0, 0, -0.2, 0.034, 0.034, 0.034],
			[0, 0, -0.235, 0.012, 0.012, 0.012],
		], 10, func(tt: float, cs: float, sn: float) -> Color:
			var col := ginger.lerp(saddle, _ss(0.3, 0.9, sn) * 0.8 * (1.0 - tt))
			col = col.lerp(cream, _ss(0.55, 0.72, tt))
			return _vary(col, Vector3(tt * 6.0, cs, sn), 0.08), 2)
	)
	tails.clear()
	tails.append(tb)
	tails.append(t2)
	tail_rest = PackedFloat32Array([-1.05, 0.35])
	# legs: 0 FL, 1 FR, 2 HL, 3 HR (left = +X)
	var fl := PackedFloat32Array([0.16, 0.17, 0.075])
	var fr := PackedFloat32Array([0.3, -0.05, -0.28])
	var hl := PackedFloat32Array([0.19, 0.2, 0.12])
	var hr := PackedFloat32Array([-0.45, 0.58, -0.12])
	var leg_fur := _lfur(ginger, ginger.lerp(cream, 0.4), -0.6)
	var front_b := [
		func(mb: MeshBuilder) -> void:
			_limb(mb, fl[0], [[-0.25, 0.042, 0.06, 0.06], [0.2, 0.045, 0.055, 0.062], [0.65, 0.032, 0.034, 0.04], [1.0, 0.027, 0.026, 0.03]], 8, _lfur(ginger, cream, -0.5)),
		func(mb: MeshBuilder) -> void:
			_limb(mb, fl[1], [[-0.1, 0.026, 0.026, 0.032], [0.15, 0.025, 0.025, 0.03], [0.75, 0.018, 0.017, 0.019], [1.05, 0.017, 0.016, 0.017]], 8, _lgrad(ginger, cream, 0.55, 1.0)),
		func(mb: MeshBuilder) -> void:
			_limb(mb, fl[2], [[-0.1, 0.018, 0.017, 0.018], [1.0, 0.017, 0.016, 0.016]], 7, _lgrad(cream, cream))
			_paw(mb, fl[2], fr[2], Vector3(0.024, 0.016, 0.032), cream),
	]
	var hind_b := [
		func(mb: MeshBuilder) -> void:
			# heavy thigh with hamstring bulge behind
			_limb(mb, hl[0], [[-0.3, 0.05, 0.07, 0.07], [0.1, 0.054, 0.068, 0.09], [0.45, 0.047, 0.055, 0.075], [0.8, 0.034, 0.036, 0.042], [1.05, 0.028, 0.027, 0.03]], 8, _lfur(ginger, cream, -0.6), 2),
		func(mb: MeshBuilder) -> void:
			# gaskin: calf muscle behind, tapering to the hock
			_limb(mb, hl[1], [[-0.1, 0.028, 0.028, 0.034], [0.25, 0.027, 0.024, 0.04], [0.7, 0.019, 0.017, 0.024], [1.0, 0.017, 0.015, 0.024]], 8, leg_fur),
		func(mb: MeshBuilder) -> void:
			# point of hock + metatarsus (white sock)
			mb.ellipsoid(Transform3D(Basis(), Vector3(0, 0.002, -0.012)), Vector3(0.015, 0.02, 0.016), ginger.lerp(cream, 0.4), 6, 4)
			_limb(mb, hl[2], [[-0.05, 0.017, 0.016, 0.02], [0.3, 0.016, 0.015, 0.017], [1.0, 0.015, 0.015, 0.015]], 7, _lgrad(ginger.lerp(cream, 0.5), cream, 0.0, 0.4))
			_paw(mb, hl[2], hr[2], Vector3(0.023, 0.016, 0.031), cream),
	]
	for s in [1.0, -1.0]:
		_leg(torso, "fleg" + ("L" if s > 0 else "R"), Vector3(0.066 * s, 0.43, 0.165) - o, fl, fr, front_b, true)
	for s in [1.0, -1.0]:
		_leg(torso, "hleg" + ("L" if s > 0 else "R"), Vector3(0.064 * s, 0.47, -0.24) - o, hl, hr, hind_b, false)
	leg_lie = [PackedFloat32Array([-1.3, -1.52, -1.55]), PackedFloat32Array([-1.3, -1.52, -1.55]),
		PackedFloat32Array([-1.2, 1.3, -1.5]), PackedFloat32Array([-1.2, 1.3, -1.5])]
	leg_dead = [PackedFloat32Array([-0.55, -0.45, -0.35]), PackedFloat32Array([-0.35, -0.3, -0.25]),
		PackedFloat32Array([0.45, 0.55, 0.45]), PackedFloat32Array([0.25, 0.4, 0.3])]
	leg_hip_y = PackedFloat32Array([0.43, 0.43, 0.47, 0.47])


# ================================================================ hoppers

func _build_hopper(mouse: bool) -> void:
	hop = true
	var top: Color
	var belly: Color
	var back: Color
	var dark: Color
	var inner_ear: Color
	var muzzle: Color
	if mouse:
		top = Color(0.82, 0.63, 0.4)
		back = Color(0.66, 0.49, 0.3)
		belly = Color(0.97, 0.94, 0.88)
		dark = Color(0.36, 0.26, 0.17)
		inner_ear = Color(0.93, 0.72, 0.68)
		muzzle = top
	else:
		top = Color(0.6, 0.48, 0.35)
		back = Color(0.5, 0.4, 0.29)
		belly = Color(0.86, 0.8, 0.7)
		dark = Color(0.2, 0.16, 0.13)
		inner_ear = Color(0.84, 0.74, 0.64)
		muzzle = Color(0.33, 0.28, 0.24)
	var rufous := Color(0.66, 0.43, 0.27)
	var sd := 10 if mouse else 14        # loft sides
	var ls := 6 if mouse else 8          # limb sides
	var hip := Vector3(0, 0.28, -0.1) if not mouse else Vector3(0, 0.24, -0.14)
	hip_y = hip.y
	torso_h = 0.33 if not mouse else 0.26
	half_w = 0.12 if not mouse else 0.15
	neck_rest = -1.0 if not mouse else -0.35
	neck_run = -0.45 if not mouse else -0.1
	neck_eat = 0.7 if not mouse else 0.2
	head_eat = 0.9 if not mouse else 0.5
	hop_f0 = 2.0 if not mouse else 3.5
	hop_f1 = 3.0 if not mouse else 6.0
	hop_min = 0.45 if not mouse else 0.8
	hop_h = 0.26 if not mouse else 0.45
	run_lean = 0.55 if not mouse else 0.25
	ear_tilt = 0.18 if not mouse else 0.35
	pad = 0.012 if not mouse else 0.012
	torso.position = hip
	var o := hip
	var tcol := func(tt: float, cs: float, sn: float) -> Color:
		var col := top.lerp(back, _ss(0.5, 0.95, sn) * 0.8)
		col = col.lerp(belly, _ss(-0.2, -0.55, sn))
		if not mouse:
			col = col.lerp(rufous, _ss(0.55, 0.9, tt) * _ss(0.0, 0.7, sn) * 0.75)
		return _vary(col, Vector3(tt * 8.0, cs, sn), 0.07)
	body_mi = _add_mesh(torso, "body", func(mb: MeshBuilder) -> void:
		if mouse:
			_body(mb, [
				[0, 0.24, -0.34, 0.05, 0.05, 0.05],
				[0, 0.26, -0.29, 0.13, 0.13, 0.12],
				[0, 0.27, -0.17, 0.16, 0.165, 0.155],
				[0, 0.27, -0.03, 0.145, 0.15, 0.14],
				[0, 0.27, 0.08, 0.12, 0.125, 0.12],
				[0, 0.28, 0.16, 0.09, 0.09, 0.09],
				[0, 0.29, 0.21, 0.055, 0.055, 0.055],
			], sd, tcol, 2, o)
		else:
			# pear-shaped: heavy haunches, narrow upright chest
			_body(mb, [
				[0, 0.235, -0.3, 0.035, 0.035, 0.035],
				[0, 0.262, -0.255, 0.09, 0.085, 0.09],
				[0, 0.29, -0.175, 0.122, 0.12, 0.125],
				[0, 0.325, -0.085, 0.118, 0.115, 0.12],
				[0, 0.37, 0.0, 0.098, 0.1, 0.104],
				[0, 0.42, 0.066, 0.082, 0.085, 0.088],
				[0, 0.468, 0.115, 0.066, 0.068, 0.072],
				[0, 0.5, 0.14, 0.048, 0.05, 0.052],
			], sd, tcol, 2, o)
	)
	# neck & head
	var neck_pos := Vector3(0, 0.49, 0.13) if not mouse else Vector3(0, 0.3, 0.17)
	neck = _node(torso, neck_pos - o)
	neck_base = neck.position
	_add_mesh(neck, "neck", func(mb: MeshBuilder) -> void:
		if mouse:
			_body(mb, [[0, 0, -0.04, 0.09, 0.09, 0.09], [0, 0, 0.02, 0.085, 0.085, 0.082], [0, 0, 0.07, 0.075, 0.075, 0.07]], sd, _lfur(top, belly, -0.25), 1)
		else:
			_body(mb, [[0, -0.005, -0.05, 0.056, 0.056, 0.062], [0, 0, 0.03, 0.046, 0.046, 0.05], [0, 0, 0.1, 0.04, 0.042, 0.045]], 12, func(tt: float, cs: float, sn: float) -> Color:
				var col: Color = _lfur(top, belly, -0.15).call(tt, cs, sn)
				return col.lerp(rufous, _ss(0.1, 0.8, sn) * 0.75), 2)
	)
	head = _node(neck, Vector3(0, 0, 0.1) if not mouse else Vector3(0, 0, 0.06))
	_add_mesh(head, "head", func(mb: MeshBuilder) -> void:
		if mouse:
			_body(mb, [
				[0, 0.02, -0.06, 0.04, 0.04, 0.04],
				[0, 0.025, -0.03, 0.082, 0.082, 0.078],
				[0, 0.025, 0.025, 0.094, 0.09, 0.085],
				[0, 0.012, 0.085, 0.07, 0.064, 0.064],
				[0, -0.004, 0.138, 0.045, 0.04, 0.04],
				[0, -0.01, 0.175, 0.024, 0.021, 0.02],
			], sd, _lfur(top, belly, -0.3), 2)
			mb.ellipsoid(Transform3D(Basis(), Vector3(0, -0.008, 0.186)), Vector3(0.018, 0.016, 0.012), Color(0.86, 0.56, 0.56), 5, 3)
			for s in [-1.0, 1.0]:
				mb.ellipsoid(Transform3D(Basis(), Vector3(0.06 * s, 0.042, 0.075)), Vector3(0.033, 0.032, 0.034), EYE, 7, 4)
				mb.ellipsoid(Transform3D(Basis(), Vector3(0.078 * s, 0.056, 0.088)), Vector3.ONE * 0.007, Color(0.9, 0.9, 0.9), 4, 2)
				# whisker tufts
				for w in 3:
					var wd := Vector3(0.9 * s, 0.1 - w * 0.12, 0.3).normalized()
					mb.tube(Vector3(0.03 * s, -0.01, 0.15), Vector3(0.03 * s, -0.01, 0.15) + wd * 0.13, 0.003, 0.0015, dark, dark, 3, false)
		else:
			_body(mb, [
				[0, 0.012, -0.045, 0.028, 0.028, 0.025],
				[0, 0.016, -0.022, 0.045, 0.047, 0.041],
				[0, 0.016, 0.015, 0.05, 0.05, 0.046],
				[0, 0.009, 0.05, 0.042, 0.04, 0.042],
				[0, -0.001, 0.085, 0.032, 0.03, 0.035],
				[0, -0.007, 0.118, 0.024, 0.022, 0.026],
				[0, -0.01, 0.14, 0.016, 0.016, 0.017],
			], sd, func(tt: float, cs: float, sn: float) -> Color:
				var col := top.lerp(back, _ss(0.5, 1.0, sn) * 0.6)
				col = col.lerp(belly, _ss(-0.3, -0.7, sn))
				# darker muzzle, pale upper-lip / cheek stripe
				col = col.lerp(muzzle, _ss(0.6, 0.85, tt) * _ss(-0.5, 0.2, sn))
				if tt > 0.4 and tt < 0.78 and absf(cs) > 0.55 and sn > -0.45 and sn < 0.05:
					col = col.lerp(belly, 0.8)
				return _vary(col, Vector3(tt * 8.0, cs, sn), 0.06), 2)
			mb.ellipsoid(Transform3D(Basis(), Vector3(0, -0.006, 0.143)), Vector3(0.017, 0.015, 0.011), NOSE, 6, 3)
			for s in [-1.0, 1.0]:
				mb.ellipsoid(Transform3D(Basis(Vector3.UP, 0.4 * s), Vector3(0.035 * s, 0.024, 0.036)), Vector3(0.012, 0.011, 0.01), EYE, 6, 4)
	)
	jaw = null
	var ear_pos := Vector3(0.028, 0.05, -0.012) if not mouse else Vector3(0.055, 0.085, 0.0)
	for s in [1.0, -1.0]:
		var e := _node(head, Vector3(ear_pos.x * s, ear_pos.y, ear_pos.z))
		_add_mesh(e, "ear" + ("L" if s > 0 else "R"), func(mb: MeshBuilder) -> void:
			var r := Vector3(0.025, 0.058, 0.01) if not mouse else Vector3(0.065, 0.11, 0.012)
			# cupped, rounded ear: back shell + slightly forward inner face
			mb.ellipsoid(Transform3D(Basis(), Vector3(0, r.y * 0.92, 0)), r, top, 8, 5, func(d: Vector3) -> Color:
				var col := top
				if d.z > 0.2 and d.y < 0.8:
					col = inner_ear
				if not mouse and d.y > 0.72:
					col = dark
				return _vary(col, d))
		)
		ears.append(e)
	# tail: thick muscular base tapering to a dark tip (wallaby) / thin with tuft (mouse)
	var tail_pos := Vector3(0, 0.232, -0.25) if not mouse else Vector3(0, 0.2, -0.31)
	var tl := PackedFloat32Array([0.26, 0.24, 0.22]) if not mouse else PackedFloat32Array([0.4, 0.4, 0.38])
	var tr := PackedFloat32Array([0.068, 0.04, 0.022, 0.007]) if not mouse else PackedFloat32Array([0.026, 0.017, 0.012, 0.008])
	var par := torso
	tails.clear()
	for i in 3:
		var n := _node(par, (tail_pos - o) if i == 0 else Vector3(0, 0, -tl[i - 1]))
		var ii := i
		_add_mesh(n, "tail" + str(i), func(mb: MeshBuilder) -> void:
			var r0 := tr[ii]
			var r1 := tr[ii + 1]
			var t0 := float(ii) / 3.0
			var fn := func(tt: float, cs: float, sn: float) -> Color:
				var g := t0 + tt / 3.0
				var col := top.lerp(back, _ss(0.3, 0.9, sn) * 0.6)
				col = col.lerp(belly, _ss(-0.3, -0.8, sn) * 0.6)
				if not mouse:
					col = col.lerp(dark, _ss(0.8, 0.97, g))
				return _vary(col, Vector3(g * 9.0, cs, sn), 0.06)
			_body(mb, [[0, 0, r0 * 0.5, r0, r0 * 0.95, r0], [0, 0, -tl[ii] * 0.5, (r0 + r1) * 0.5, (r0 + r1) * 0.47, (r0 + r1) * 0.5], [0, 0, -tl[ii], r1, r1 * 0.95, r1]], 9 if not mouse else 6, fn, 1, Vector3.ZERO, ii == 2)
			if ii == 2 and mouse:
				_body(mb, [[0, 0, -tl[ii] + 0.02, 0.012, 0.012, 0.012], [0, 0.005, -tl[ii] - 0.05, 0.034, 0.036, 0.03], [0, 0.005, -tl[ii] - 0.13, 0.03, 0.03, 0.028], [0, 0.0, -tl[ii] - 0.19, 0.008, 0.008, 0.008]], 6, _lgrad(dark.lightened(0.15), dark), 1)
		)
		tails.append(n)
		par = n
	tail_rest = PackedFloat32Array([-0.55, 0.35, 0.2]) if not mouse else PackedFloat32Array([-0.25, 0.12, 0.12])
	# forelegs (arms) hang in front of the chest; rotation relative to torso
	var arm_pos := Vector3(0.05, 0.43, 0.12) if not mouse else Vector3(0.065, 0.2, 0.17)
	var al := PackedFloat32Array([0.09, 0.085]) if not mouse else PackedFloat32Array([0.07, 0.07])
	var ar := PackedFloat32Array([0.024, 0.016, 0.011]) if not mouse else PackedFloat32Array([0.026, 0.017, 0.013])
	arm_rest = Vector2(-0.35, -0.9) if not mouse else Vector2(-0.2, -0.7)
	arms = []
	var hand_c := dark if not mouse else belly
	for s in [1.0, -1.0]:
		var a0 := _node(torso, Vector3(arm_pos.x * s, arm_pos.y, arm_pos.z) - o)
		_add_mesh(a0, "arm0", func(mb: MeshBuilder) -> void:
			_limb(mb, al[0], [[-0.25, ar[0] * 1.2, ar[0] * 1.3, ar[0] * 1.3], [0.3, ar[0], ar[0], ar[0] * 1.1], [1.1, ar[1], ar[1], ar[1]]], ls, _lfur(top, belly, -0.3))
		)
		var a1 := _node(a0, Vector3(0, -al[0], 0))
		_add_mesh(a1, "arm1", func(mb: MeshBuilder) -> void:
			_limb(mb, al[1], [[-0.05, ar[1], ar[1], ar[1]], [1.0, ar[2], ar[2], ar[2]]], ls, _lgrad(top.lerp(belly, 0.3), hand_c, 0.6, 1.0))
			mb.ellipsoid(Transform3D(Basis(), Vector3(0, -al[1] - ar[2], 0.004)), Vector3(ar[2] * 1.4, ar[2] * 1.6, ar[2] * 1.5), hand_c, 6, 3)
		)
		arms.append([a0, a1])
	# hind legs: huge thigh, long shin, long narrow foot (toes forward)
	var hlen := PackedFloat32Array([0.16, 0.2, 0.2]) if not mouse else PackedFloat32Array([0.13, 0.15, 0.2])
	var hrest := PackedFloat32Array([hop_rest.x, hop_rest.y, hop_rest.z])
	var foot_c := dark if not mouse else belly
	var hb := [
		func(mb: MeshBuilder) -> void:
			if mouse:
				_limb(mb, hlen[0], [[-0.35, 0.06, 0.07, 0.07], [0.1, 0.062, 0.075, 0.075], [0.55, 0.048, 0.05, 0.055], [1.05, 0.026, 0.024, 0.028]], ls, _lfur(top, belly, -0.5), 2)
			else:
				_limb(mb, hlen[0], [[-0.35, 0.07, 0.09, 0.085], [0.05, 0.075, 0.1, 0.1], [0.45, 0.065, 0.085, 0.085], [0.8, 0.042, 0.045, 0.05], [1.05, 0.03, 0.028, 0.033]], 10, _lfur(top, belly, -0.5), 2),
		func(mb: MeshBuilder) -> void:
			var k0 := 0.03 if not mouse else 0.024
			_limb(mb, hlen[1], [[-0.08, k0, k0 * 0.95, k0 * 1.2], [0.35, k0 * 0.85, k0 * 0.75, k0 * 1.05], [1.0, k0 * 0.58, k0 * 0.5, k0 * 0.62]], ls, _lfur(top, belly, -0.5)),
		func(mb: MeshBuilder) -> void:
			var fw := 0.021 if not mouse else 0.02
			# heel -> toes; +Z side (front) is the top of the foot when it lies flat
			_limb(mb, hlen[2], [[-0.06, fw * 0.9, fw * 0.9, fw * 1.2], [0.15, fw, fw * 0.9, fw * 0.95], [0.7, fw * 0.95, fw * 0.75, fw * 0.8], [0.92, fw * 0.7, fw * 0.55, fw * 0.6], [1.03, fw * 0.35, fw * 0.3, fw * 0.3]], ls, func(tt: float, cs: float, sn: float) -> Color:
				var col := top.lerp(foot_c, _ss(0.0, -0.6, sn) * 0.85)
				col = col.lerp(foot_c, _ss(0.75, 0.95, tt))
				return _vary(col, Vector3(tt * 5.0, cs, sn), 0.06), 2),
	]
	for s in [1.0, -1.0]:
		var hp := Vector3((0.085 if not mouse else 0.1) * s, hip.y, hip.z)
		_leg(root, "hleg" + ("L" if s > 0 else "R"), hp, hlen, hrest, hb, false)


# ================================================================ update

func update_rig(dt: float) -> void:
	if c == null:
		return
	dt = clampf(dt, 0.0, 0.1)
	t += dt
	var L := maxf(c.length, 0.001)
	var ws := maxf(0.01, c.walk_speed())
	var rs := maxf(ws + 0.01, c.run_speed())
	var spd := c.speed if not dead else 0.0
	var k6 := 1.0 - exp(-6.0 * dt)
	move_w = lerpf(move_w, clampf(spd / (ws * 0.6), 0.0, 1.0), 1.0 - exp(-8.0 * dt))
	run_w = lerpf(run_w, clampf((spd - ws) / (rs - ws), 0.0, 1.0), 1.0 - exp(-5.0 * dt))
	var eating := c.action == "eat" or c.action == "drink"
	eat_w = move_toward(eat_w, 1.0 if eating and not dead else 0.0, dt * 3.0)
	var rest_a := c.rest_amt if not dead else 0.0
	# ---- gait phase from distance travelled (no foot skate)
	var dg := c.gait_phase - _last_gp
	_last_gp = c.gait_phase
	if dg < 0.0 or dg > 4.0:
		dg = 0.0
	var dist := dg * c.stride() / L          # in body lengths
	var cyc: float
	if hop:
		cyc = maxf(hop_min, spd / L / lerpf(hop_f0, hop_f1, run_w))
	else:
		cyc = lerpf(stride0, stride1, run_w)
	phase = fposmod(phase + dist / maxf(cyc, 0.001), 1.0)
	# ---- terrain pitch
	var f := c.fwd()
	var tp := 0.0
	if not dead and not c.swimming:
		var hf := c.terrain.height(c.position.x + f.x * L * 0.35, c.position.z + f.z * L * 0.35)
		var hb := c.terrain.height(c.position.x - f.x * L * 0.35, c.position.z - f.z * L * 0.35)
		tp = -atan2(hf - hb, L * 0.7)
	t_pitch = lerpf(t_pitch, clampf(tp, -0.6, 0.6), k6)
	# ---- head look target
	look_timer -= dt
	if look_timer <= 0.0:
		look_timer = randf_range(1.2, 4.0)
		look_goal = randf_range(-0.8, 0.8) if move_w < 0.3 else randf_range(-0.12, 0.12)
		look_goal_p = randf_range(-0.2, 0.25)
	var ty := look_goal
	var tpch := look_goal_p * (1.0 - move_w)
	if c.brain != null and c.brain.get("look_point") is Vector3:
		var lp: Vector3 = c.brain.get("look_point")
		var dl := lp - c.position
		ty = clampf(wrapf(atan2(dl.x, dl.z) - c.yaw, -PI, PI), -1.1, 1.1)
		tpch = clampf(-atan2(dl.y - L * 0.5, Vector2(dl.x, dl.z).length()), -0.5, 0.5)
	if eating:
		ty = sin(c.action_t * 0.9) * 0.2
	if dead:
		ty = 0.0
		tpch = 0.0
	head_yaw = lerpf(head_yaw, ty, 1.0 - exp(-4.0 * dt))
	head_pitch = lerpf(head_pitch, tpch, 1.0 - exp(-4.0 * dt))
	# ---- bite timing
	var bite_k := -1.0
	if bite_t >= 0.0:
		bite_t += dt
		bite_k = bite_t / maxf(0.2, c.action_len if c.action_len > 0.0 else 0.45)
		if bite_k >= 1.0:
			bite_t = -1.0
			bite_k = -1.0
	var lunge := sin(clampf(bite_k, 0.0, 1.0) * PI) if bite_k >= 0.0 else 0.0
	hit_t = maxf(0.0, hit_t - dt)
	if dead:
		dead_amt = move_toward(dead_amt, 1.0, dt * 2.2)
	if hop:
		_pose_hop(dt, L, rs, rest_a, lunge, bite_k)
	else:
		_pose_quad(dt, rest_a, lunge, bite_k)
	# ---- ears
	ear_timer -= dt
	if ear_timer <= 0.0:
		ear_timer = randf_range(1.0, 5.0)
		ear_side = randi() % 2
		ear_t = 0.25
	ear_t = maxf(0.0, ear_t - dt)
	var flat := maxf(c.posture_amt, 1.0 if bite_k >= 0.0 else 0.0) * (0.0 if dead else 1.0)
	flat = maxf(flat, run_w * 0.6)
	for i in ears.size():
		var s := 1.0 if i == 0 else -1.0
		var tw := sin(ear_t / 0.25 * PI) * 0.5 if (i == ear_side and ear_t > 0.0) else 0.0
		var rx := -0.9 * flat - tw - 0.25 * rest_a
		if dead:
			rx = -0.7 * dead_amt
		ears[i].rotation = Vector3(rx, 0.15 * s * flat, -ear_tilt * s * (1.0 + 0.8 * flat))
	# ---- breathing
	if body_mi != null:
		var br := 1.0 + sin(t * (2.0 + 5.0 * run_w)) * (0.015 + 0.02 * run_w) * (1.0 - dead_amt)
		body_mi.scale = Vector3(br, br, 1.0)
	# ---- whole body: jolt, death roll
	var jolt := sin(hit_t * 45.0) * hit_t * 0.35 + c.flinch * 0.12
	var roll := _ss(0.0, 1.0, dead_amt) * PI * 0.5
	root.position = Vector3(torso_h * sin(roll), lerpf(y_off, half_w, sin(roll)), -jolt * 0.1)
	root.rotation = Vector3(t_pitch * (1.0 - dead_amt) - jolt * 0.5, 0.0, roll + jolt * 0.3)


func _apply_leg(k: int, ang: PackedFloat32Array, base: float, splay := 0.0) -> void:
	var nodes: Array = legs[k]
	var prev := base
	for i in nodes.size():
		var n: Node3D = nodes[i]
		n.rotation = Vector3(ang[i] - prev, 0.0, splay if i == 0 else 0.0)
		prev = ang[i]


## Lowest point of a leg (relative to its hip, negative = below).
func _leg_low(k: int, ang: PackedFloat32Array) -> float:
	var lens: PackedFloat32Array = leg_len[k]
	var y := 0.0
	var lo := 0.0
	for i in lens.size():
		y -= lens[i] * cos(ang[i])
		lo = minf(lo, y)
	return lo - pad


func _mix(a: PackedFloat32Array, b: PackedFloat32Array, w: float) -> PackedFloat32Array:
	if w <= 0.0:
		return a
	var r := a.duplicate()
	for i in r.size():
		r[i] = lerpf(a[i], b[i], w)
	return r


# ---------------------------------------------------------------- quadruped

func _pose_quad(dt: float, rest_a: float, lunge: float, bite_k: float) -> void:
	var tw := _ss(0.0, 0.2, run_w)
	var gw := _ss(0.45, 0.85, run_w)
	# phase offsets: FL, FR, HL, HR
	var walk := [0.25, 0.75, 0.0, 0.5]
	var trot := [0.0, 0.5, 0.5, 0.0]
	var gal := [0.58, 0.7, 0.0, 0.1]
	var duty := lerpf(lerpf(0.64, 0.5, tw), 0.38, gw)
	var cyc := lerpf(stride0, stride1, run_w)
	var amp := asin(clampf(duty * cyc / (2.0 * leg_h), 0.0, 0.7)) * move_w
	var lf_scale := clampf(0.4 + move_w * 0.6, 0.0, 1.0) * move_w
	var angs: Array = []
	var lows := PackedFloat32Array()
	for k in 4:
		var off := lerpf(lerpf(walk[k], trot[k], tw), gal[k], gw)
		var q := fposmod(phase + off, 1.0)
		var rest: PackedFloat32Array = leg_rest[k]
		var a := rest.duplicate()
		var s: float
		var lift := 0.0
		if q < duty:
			s = lerpf(-1.0, 1.0, q / duty)
		else:
			var w := (q - duty) / (1.0 - duty)
			s = cos(w * PI)
			lift = sin(w * PI) * lf_scale
		var sw := s * amp
		for i in 3:
			a[i] += sw
		if leg_front[k]:
			a[0] -= lift * 0.25
			a[1] -= lift * (0.6 + 0.5 * gw)
			a[2] += lift * (1.5 + 0.5 * gw)
		else:
			a[0] -= lift * (0.35 + 0.3 * gw)
			a[1] += lift * 0.75
			a[2] -= lift * 0.55
		# eating: front legs brace slightly
		if leg_front[k] and eat_w > 0.0:
			a[0] -= 0.12 * eat_w
			a[1] += 0.05 * eat_w
		a = _mix(a, leg_lie[k], _ss(0.0, 0.8, rest_a))
		if dead_amt > 0.0:
			a = _mix(a, leg_dead[k], dead_amt)
		angs.append(a)
		lows.append(leg_hip_y[k] + _leg_low(k, a))
	var yf := minf(lows[0], lows[1])
	var yh := minf(lows[2], lows[3])
	var dz := 0.4
	var lp := clampf(atan2(yf - yh, dz), -0.18, 0.18) * (1.0 - rest_a)
	# gallop spine rock
	lp += sin(phase * TAU) * 0.06 * gw
	leg_pitch = lerpf(leg_pitch, lp, 1.0 - exp(-14.0 * dt))
	var y_g := -yh
	y_off = lerpf(y_g, -lie_drop, _ss(0.0, 1.0, rest_a))
	if dead_amt > 0.0:
		y_off = lerpf(y_off, 0.0, dead_amt)
	var tors := leg_pitch * (1.0 - dead_amt)
	torso.rotation = Vector3(tors, 0.0, 0.0)
	for k in 4:
		var splay := 0.0
		if dead_amt > 0.0:
			splay = (0.12 if k % 2 == 0 else -0.12) * dead_amt
		_apply_leg(k, angs[k], tors, splay)
	# ---- neck / head
	var nrx := lerpf(neck_rest, neck_run, run_w)
	nrx = lerpf(nrx, -0.2, c.posture_amt)
	nrx = lerpf(nrx, 0.1, _ss(0.3, 1.0, rest_a))
	nrx = lerpf(nrx, neck_eat, eat_w)
	var hp := head_pitch
	hp = lerpf(hp, 0.25, c.posture_amt)
	hp = lerpf(hp, 0.12, _ss(0.3, 1.0, rest_a))
	var chew := 0.0
	if eat_w > 0.0:
		var eat_bob := sin(c.action_t * 5.0) * 0.12
		hp = lerpf(hp, head_eat + eat_bob, eat_w)
		nrx += sin(c.action_t * 2.5) * 0.08 * eat_w
		if c.action == "eat":
			chew = maxf(0.0, sin(c.action_t * 11.0)) * 0.3 * eat_w
		else:
			chew = maxf(0.0, sin(c.action_t * 14.0)) * 0.08 * eat_w
	# trot head bob
	nrx += sin(phase * TAU * 2.0) * 0.04 * move_w * (1.0 - gw)
	var nz := 0.0
	if lunge > 0.0:
		nrx = lerpf(nrx, -0.1, lunge)
		hp = lerpf(hp, -0.05, lunge)
		nz = 0.06 * lunge
	if dead_amt > 0.0:
		nrx = lerpf(nrx, 0.15, dead_amt)
		hp = lerpf(hp, 0.25, dead_amt)
	neck.position = neck_base + Vector3(0, -nz * 0.3, nz)
	neck.rotation = Vector3(nrx, head_yaw * 0.55, 0.0)
	head.rotation = Vector3(-nrx - tors + hp, head_yaw * 0.45, 0.0)
	if jaw != null:
		var open := 0.0
		if bite_k >= 0.0:
			open = 0.75 * _ss(0.0, 0.25, bite_k) * (1.0 - _ss(0.3, 0.4, bite_k))
		open = maxf(open, chew)
		open = maxf(open, run_w * (0.15 + 0.05 * sin(t * 9.0)) * (1.0 - dead_amt))
		open = maxf(open, 0.15 * dead_amt)
		jaw.rotation = Vector3(open, 0.0, 0.0)
	# ---- tail
	var trx := lerpf(tail_rest[0], -0.55, run_w)
	trx = lerpf(trx, -0.3, c.posture_amt)
	trx = lerpf(trx, -1.35, _ss(0.3, 1.0, rest_a))
	trx = lerpf(trx, -1.3, dead_amt)
	var wag := sin(t * 2.3) * 0.12 * (1.0 - move_w) + sin(phase * TAU) * 0.1 * move_w
	wag *= (1.0 - dead_amt)
	var curl := 0.9 * _ss(0.3, 1.0, rest_a)
	tails[0].rotation = Vector3(trx - tors, wag + curl, 0.0)
	tails[1].rotation = Vector3(tail_rest[1] * (1.0 - dead_amt) + sin(phase * TAU * 2.0) * 0.08 * gw, wag * 1.3 + curl * 0.8, 0.0)


# ---------------------------------------------------------------- hopper

func _hop_leg(q: float, D: float, amp: float) -> Vector3:
	var th: float
	var sh: float
	var ft: float
	if q < D:
		var w := q / D
		th = lerpf(-1.2, 0.2, w)
		sh = lerpf(0.5, 0.85, w) + 0.35 * sin(w * PI)
		ft = lerpf(-1.48, -0.25, _ss(0.35, 1.0, w))
	else:
		var w := (q - D) / (1.0 - D)
		var back := sin(minf(w / 0.35, 1.0) * PI * 0.5) * (1.0 - _ss(0.35, 1.0, w))
		var fw := _ss(0.3, 0.95, w)
		th = lerpf(0.2 + 0.25 * back, -1.2, fw)
		sh = lerpf(0.85 + 0.3 * back, 0.5, fw)
		ft = lerpf(-0.25 + 0.55 * back, -1.48, fw)
	return hop_rest.lerp(Vector3(th, sh, ft), amp)


func _hop_ground(v: Vector3) -> float:
	var a := PackedFloat32Array([v.x, v.y, v.z])
	return -(hip_y + _leg_low(0, a))


func _pose_hop(dt: float, L: float, rs: float, rest_a: float, lunge: float, bite_k: float) -> void:
	var D := lerpf(0.55, 0.4, run_w)
	var amp := move_w * lerpf(0.55, 1.0, run_w)
	var crouch := _ss(0.0, 0.8, rest_a)
	var pose := _hop_leg(phase, D, amp).lerp(hop_crouch, crouch)
	var yg := _hop_ground(pose)
	var y := yg
	var flight_w := 0.0
	if phase >= D and amp > 0.01:
		var w := (phase - D) / (1.0 - D)
		flight_w = sin(w * PI)
		var y0 := _hop_ground(_hop_leg(D, D, amp).lerp(hop_crouch, crouch))
		var y1 := _hop_ground(_hop_leg(0.0, D, amp).lerp(hop_crouch, crouch))
		var hh := hop_h * clampf(c.speed / rs, 0.15, 1.0) * move_w
		y = maxf(lerpf(y0, y1, w) + hh * 4.0 * w * (1.0 - w), yg)
	y_off = lerpf(y, 0.0, dead_amt)
	var a := PackedFloat32Array([pose.x, pose.y, pose.z])
	if dead_amt > 0.0:
		a = _mix(a, PackedFloat32Array([0.5, 0.7, 0.4]), dead_amt)
	for k in 2:
		_apply_leg(k, a, 0.0, (0.1 if k == 0 else -0.1) * dead_amt)
	# ---- torso lean
	var ln := run_lean * run_w * move_w
	ln += 0.12 * move_w * (1.0 - run_w)
	ln += sin(phase * TAU) * 0.06 * amp
	var mouse := c.species_id == "mouse"
	if eat_w > 0.0:
		ln = lerpf(ln, -0.3 if mouse else 0.75, eat_w)
	ln = lerpf(ln, 0.15 if mouse else 0.3, crouch)
	ln = lerpf(ln, 0.0, dead_amt)
	lean = lerpf(lean, ln, 1.0 - exp(-8.0 * dt))
	torso.rotation = Vector3(lean, 0.0, 0.0)
	# ---- arms (relative to torso)
	var ax := arm_rest.x - 0.35 * run_w * move_w
	var ay := arm_rest.y - 0.3 * run_w * move_w
	if eat_w > 0.0:
		if mouse:
			ax = lerpf(ax, -1.25, eat_w)
			ay = lerpf(ay, -2.3 + sin(c.action_t * 12.0) * 0.1, eat_w)
		else:
			ax = lerpf(ax, -0.72, eat_w)
			ay = lerpf(ay, -0.78, eat_w)
	if crouch > 0.0 and not mouse:
		ax = lerpf(ax, -0.25, crouch)
		ay = lerpf(ay, -0.55, crouch)
	if dead_amt > 0.0:
		ax = lerpf(ax, -0.6, dead_amt)
		ay = lerpf(ay, -0.8, dead_amt)
	for arm in arms:
		var a0: Node3D = arm[0]
		var a1: Node3D = arm[1]
		a0.rotation = Vector3(ax, 0.0, 0.0)
		a1.rotation = Vector3(ay - ax, 0.0, 0.0)
	# ---- neck & head
	var nrx := lerpf(neck_rest, neck_run, run_w * move_w) - lean * 0.6
	var hp := head_pitch
	var chew := 0.0
	if eat_w > 0.0:
		nrx = lerpf(nrx, neck_eat - lean * 0.3, eat_w)
		hp = lerpf(hp, head_eat + sin(c.action_t * 4.0) * 0.1, eat_w)
		chew = sin(c.action_t * 13.0) * 0.06 * eat_w
	nrx = lerpf(nrx, nrx + 0.35, crouch)
	if lunge > 0.0:
		nrx = lerpf(nrx, neck_rest + 0.6, lunge)
	if dead_amt > 0.0:
		nrx = lerpf(nrx, 0.3, dead_amt)
		hp = lerpf(hp, 0.2, dead_amt)
	neck.rotation = Vector3(nrx, head_yaw * 0.5, 0.0)
	head.rotation = Vector3(-nrx - lean + hp + chew, head_yaw * 0.5, 0.0)
	# ---- tail (counter-swing to the legs, rests on the ground when still)
	var leg_d := pose.x - hop_rest.x
	var t0 := lerpf(tail_rest[0], -0.2 if not mouse else -0.1, run_w * move_w) - leg_d * 0.35 * amp
	t0 = lerpf(t0, tail_rest[0] - 0.1, crouch)
	var t1 := tail_rest[1] * (1.0 - 0.6 * run_w * move_w) + leg_d * 0.2 * amp
	var t2 := tail_rest[2] + leg_d * 0.15 * amp
	var sway := sin(t * 1.3) * 0.08 * (1.0 - move_w)
	if dead_amt > 0.0:
		t0 = lerpf(t0, -0.1, dead_amt)
		t1 = lerpf(t1, 0.05, dead_amt)
		t2 = lerpf(t2, 0.05, dead_amt)
		sway = 0.0
	tails[0].rotation = Vector3(t0 - lean, sway, 0.0)
	tails[1].rotation = Vector3(t1, sway * 1.5, 0.0)
	tails[2].rotation = Vector3(t2, sway * 2.0, 0.0)
