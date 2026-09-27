class_name SmallRig
extends Node3D
## Procedural rig for small creatures, selected by sp.rig:
##   "frog"   - green tree frog: squat body, bulging eyes, folded hind legs, hops
##   "insect" - grasshopper: long body, big folded hind legs, antennae, jumps
##   "fish"   - spangled perch: spindle body, spots, fins, tail-driven swimming
## Parts are rigid vertex-coloured meshes on joint pivots, built once per
## species in normalised units (length = 1) and shared; the rig node is scaled
## by creature.length. Local +Z forward, +Y up, +X = left side.

static var _cache := {}
static var _mat: StandardMaterial3D = null

var c: Creature
var kind := "frog"
var root := Node3D.new()
var body: Node3D
var body_mi: MeshInstance3D
var head: Node3D
var rear: Node3D           # fish rear body
var tailfin: Node3D
var hind: Array = []       # per hind leg: Array of pivots
var fore: Array = []       # per small leg: Array of pivots
var fore_base: Array = []  # per small leg: Vector3 base rotation of the top pivot

var phase := 0.0
var _last_gp := 0.0
var t := 0.0
var move_w := 0.0
var run_w := 0.0
var eat_w := 0.0
var t_pitch := 0.0
var swim_ph := 0.0
var _prev_yaw := 0.0
var yaw_rate := 0.0
var bite_t := -1.0
var hit_t := 0.0
var dead := false
var dead_amt := 0.0
var hop_len := 0.0
var twitch_t := 0.0
var twitch_timer := 1.0
var body_pitch := 0.0


func setup(creature: Creature) -> void:
	c = creature
	kind = str(c.sp.get("rig", "frog"))
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true
		_mat.vertex_color_is_srgb = true
		_mat.roughness = 0.7
	add_child(root)
	match kind:
		"fish":
			_build_fish()
		"insect":
			_build_insect()
		_:
			kind = "frog"
			_build_frog()
	on_resize()
	_last_gp = c.gait_phase
	_prev_yaw = c.yaw
	phase = 0.0
	t = randf() * 10.0
	swim_ph = randf() * TAU


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


static func _otri(mb: MeshBuilder, a: Vector3, b: Vector3, cc: Vector3, col: Color, want: Vector3) -> void:
	if (b - a).cross(cc - a).dot(want) < 0.0:
		mb.tri(a, cc, b, col, col, col)
	else:
		mb.tri(a, b, cc, col, col, col)


## Flat slab from a star-shaped 2D outline (x, z), thickness along local Y.
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
	var ce := ctop.darkened(0.15) if cedge.r < 0.0 else cedge
	for i in n:
		var j := (i + 1) % n
		_otri(mb, ct, top[i], top[j], ctop, up)
		_otri(mb, cb, bot[i], bot[j], cbot, -up)
		var out := (top[i] + top[j]) * 0.5 - ct
		_otri(mb, top[i], bot[i], bot[j], ce, out)
		_otri(mb, top[i], bot[j], top[j], ce, out)


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


## Basis that maps the slab's (x, thickness, z) to (up, side, forward): a vertical fin.
static func _vfin() -> Basis:
	return Basis(Vector3(0, 1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1))


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


# ================================================================ frog

const FROG_REST := [Vector2(0.12, 0.85), Vector2(0.05, 2.55), Vector2(-0.05, -2.85)]   # (pitch, yaw*side) per segment, relative
const FROG_PUSH := [Vector2(0.55, 2.75), Vector2(-0.15, 0.15), Vector2(-0.25, 0.1)]
const FROG_TRAIL := [Vector2(0.15, 2.85), Vector2(0.0, 0.12), Vector2(0.05, 0.15)]


func _build_frog() -> void:
	var green := Color(0.34, 0.62, 0.2)
	var dgreen := Color(0.26, 0.5, 0.15)
	var belly := Color(0.93, 0.91, 0.76)
	var pad := Color(0.78, 0.8, 0.6)
	var skin := func(d: Vector3) -> Color:
		var col := green.lerp(dgreen, _ss(0.5, 1.0, d.y) * 0.4)
		if _hash3(d * 3.0) > 0.93 and d.y > 0.2:
			col = col.lerp(Color(0.85, 0.92, 0.7), 0.6)
		col = col.lerp(belly, _ss(-0.15, -0.45, d.y))
		return _vary(col, d, 0.06)
	body = _node(root, Vector3(0, 0.15, -0.05))
	body_mi = _add_mesh(body, "body", func(mb: MeshBuilder) -> void:
		mb.ellipsoid(Transform3D(Basis(Vector3.RIGHT, -0.2), Vector3(0, 0.0, 0.03)), Vector3(0.23, 0.15, 0.33), green, 12, 8, skin)
		mb.ellipsoid(Transform3D(Basis(Vector3.RIGHT, -0.1), Vector3(0, 0.03, 0.25)), Vector3(0.2, 0.11, 0.15), green, 12, 7, skin)
		# white lip stripe
		mb.ellipsoid(Transform3D(Basis(Vector3.RIGHT, -0.1), Vector3(0, 0.005, 0.26)), Vector3(0.195, 0.03, 0.14), belly, 10, 4)
		for s in [-1.0, 1.0]:
			mb.ellipsoid(Transform3D(Basis(), Vector3(0.12 * s, 0.11, 0.28)), Vector3(0.075, 0.065, 0.07), green, 8, 5, skin)
			mb.ellipsoid(Transform3D(Basis(), Vector3(0.14 * s, 0.125, 0.3)), Vector3.ONE * 0.06, Color(0.72, 0.52, 0.14), 8, 5)
			mb.ellipsoid(Transform3D(Basis(), Vector3(0.19 * s, 0.13, 0.315)), Vector3(0.012, 0.018, 0.032), Color(0.02, 0.02, 0.02), 5, 3)
	)
	# hind legs (sprawled, folded Z-shape in the horizontal plane; segments along +Z)
	var lens := [0.28, 0.28, 0.25]
	var rads := [0.075, 0.048, 0.032, 0.02]
	for i in 2:
		var s := 1.0 if i == 0 else -1.0
		var par := root
		var nodes: Array[Node3D] = []
		for k in 3:
			var n := _node(par, Vector3(0.13 * s, 0.1, -0.2) if k == 0 else Vector3(0, 0, lens[k - 1]))
			var kk := k
			_add_mesh(n, "hleg" + str(k) + ("L" if s > 0 else "R"), func(mb: MeshBuilder) -> void:
				var ln: float = lens[kk]
				mb.ellipsoid(Transform3D(Basis(), Vector3(0, 0, ln * 0.5)), Vector3(rads[kk], rads[kk] * 0.85, ln * 0.55), green, 8, 5, skin)
				if kk == 2:
					for a in [-0.45, -0.1, 0.25, 0.6]:
						var d := Vector3(sin(a) * s, 0, cos(a))
						var st := Vector3(0, 0, ln * 0.9)
						mb.tube(st, st + d * 0.12, 0.014, 0.01, green, green, 4, false)
						mb.ellipsoid(Transform3D(Basis(), st + d * 0.13), Vector3(0.022, 0.012, 0.022), pad, 5, 3)
			)
			nodes.append(n)
			par = n
		hind.append(nodes)
	# front legs (attached to body): upper + forearm with pads, hanging down
	for i in 2:
		var s := 1.0 if i == 0 else -1.0
		var a0 := _node(body, Vector3(0.14 * s, -0.05, 0.2))
		_add_mesh(a0, "farm0" + ("L" if s > 0 else "R"), func(mb: MeshBuilder) -> void:
			mb.tube(Vector3.ZERO, Vector3(0, -0.11, 0), 0.035, 0.026, green, green, 6, false)
			mb.ellipsoid(Transform3D(Basis(), Vector3.ZERO), Vector3.ONE * 0.035, green, 6, 4)
		)
		var a1 := _node(a0, Vector3(0, -0.11, 0))
		_add_mesh(a1, "farm1" + ("L" if s > 0 else "R"), func(mb: MeshBuilder) -> void:
			mb.tube(Vector3.ZERO, Vector3(0, -0.07, 0.03), 0.026, 0.02, green, green, 6, false)
			mb.ellipsoid(Transform3D(Basis(), Vector3.ZERO), Vector3.ONE * 0.026, green, 6, 4)
			for a in [-0.5, 0.0, 0.5]:
				var d := Vector3(sin(a) * s, -0.1, cos(a))
				mb.tube(Vector3(0, -0.07, 0.03), Vector3(0, -0.07, 0.03) + d * 0.06, 0.01, 0.008, green, green, 4, false)
				mb.ellipsoid(Transform3D(Basis(), Vector3(0, -0.075, 0.03) + d * 0.065), Vector3(0.016, 0.009, 0.016), pad, 5, 3)
		)
		fore.append([a0, a1])
		fore_base.append(Vector3(-0.35, 0.0, 0.35 * s))


func _update_frog(dt: float, L: float, rs: float, spd: float, lunge: float) -> void:
	var swim := c.swimming and not dead
	var D := 0.28
	var y_off := 0.0
	var pitch := 0.0
	var poses: Array = [FROG_REST[0], FROG_REST[1], FROG_REST[2]]
	var amp := move_w
	var fore_x := 0.0
	if swim:
		# breast-stroke kicks
		swim_ph += dt * (2.0 + spd / L * 0.8)
		var k := fposmod(swim_ph / TAU, 1.0)
		var ext := _ss(0.0, 0.25, k) * (1.0 - _ss(0.45, 1.0, k))
		for i in 3:
			var a: Vector2 = FROG_REST[i]
			var b: Vector2 = FROG_TRAIL[i]
			poses[i] = a.lerp(b, ext)
		y_off = -0.05
		fore_x = -0.9
	elif amp > 0.01:
		var q := phase
		if q < D:
			var w := q / D
			for i in 3:
				var a: Vector2 = FROG_REST[i]
				var b: Vector2 = FROG_PUSH[i]
				poses[i] = a.lerp(b, _ss(0.0, 1.0, w) * amp)
			y_off = 0.1 * _ss(0.2, 1.0, w) * amp
			pitch = -0.45 * _ss(0.0, 1.0, w) * amp
			fore_x = -0.3 * w
		else:
			var w := (q - D) / (1.0 - D)
			var fold := _ss(0.5, 0.95, w)
			for i in 3:
				var a: Vector2 = FROG_PUSH[i]
				var b: Vector2 = FROG_TRAIL[i]
				var r: Vector2 = FROG_REST[i]
				poses[i] = r.lerp(a.lerp(b, _ss(0.0, 0.3, w)).lerp(r, fold), amp)
			var hh := clampf(hop_len * 0.35, 0.15, 3.0) * amp
			y_off = lerpf(0.1 * amp, 0.0, w) + hh * 4.0 * w * (1.0 - w)
			pitch = lerpf(-0.45, 0.25, w) * amp
			fore_x = lerpf(-0.3, -1.1, _ss(0.3, 0.8, w)) * amp
	# resting: tuck lower
	y_off -= 0.03 * c.rest_amt
	# eating: gulp squash
	var sq := 1.0
	if eat_w > 0.0:
		sq = 1.0 - maxf(0.0, sin(c.action_t * 6.0)) * 0.08 * eat_w
		pitch += 0.12 * eat_w
	pitch += lunge * 0.35
	var br := 1.0 + sin(t * 3.5) * 0.02 * (1.0 - dead_amt)
	body_mi.scale = Vector3(br, br * sq, 1.0)
	for i in 2:
		var s := 1.0 if i == 0 else -1.0
		var nodes: Array = hind[i]
		for k in 3:
			var p: Vector2 = poses[k]
			if dead_amt > 0.0:
				var dp: Vector2 = FROG_TRAIL[k]
				p = p.lerp(Vector2(-0.2 if k == 0 else 0.1, dp.y), dead_amt)
			var n: Node3D = nodes[k]
			n.rotation = Vector3(p.x, p.y * s, 0.0)
	for i in 2:
		var arm: Array = fore[i]
		var base: Vector3 = fore_base[i]
		var a0: Node3D = arm[0]
		var a1: Node3D = arm[1]
		a0.rotation = base + Vector3(fore_x - pitch * 0.8, 0.0, 0.0)
		a1.rotation = Vector3(0.25, 0.0, 0.0)
	body_pitch = lerpf(body_pitch, pitch, 1.0 - exp(-14.0 * dt))
	body.rotation = Vector3(body_pitch, 0.0, 0.0)
	# dead frogs end up belly-up
	var roll := _ss(0.0, 1.0, dead_amt) * PI
	root.position = Vector3(0, y_off * (1.0 - dead_amt) + 0.24 * sin(roll * 0.5), 0)
	root.rotation = Vector3(t_pitch * (1.0 - dead_amt), 0.0, roll)


# ================================================================ grasshopper

const GH_LEN: Array[float] = [0.35, 0.33, 0.1]


func _build_insect() -> void:
	var olive := Color(0.44, 0.47, 0.22)
	var dolive := Color(0.3, 0.32, 0.15)
	var tan := Color(0.62, 0.55, 0.32)
	var brown := Color(0.48, 0.38, 0.22)
	var yel := Color(0.75, 0.7, 0.4)
	var skin := func(d: Vector3) -> Color:
		var col := olive.lerp(dolive, _ss(0.4, 1.0, d.y) * 0.5)
		col = col.lerp(yel, _ss(-0.3, -0.7, d.y))
		return _vary(col, d, 0.1)
	body = _node(root, Vector3(0, 0.1, 0.0))
	body_mi = _add_mesh(body, "body", func(mb: MeshBuilder) -> void:
		mb.ellipsoid(Transform3D(Basis(), Vector3(0, 0.01, 0.02)), Vector3(0.068, 0.072, 0.16), olive, 8, 5, skin)
		# pronotum saddle with pale lateral stripe
		mb.ellipsoid(Transform3D(Basis(), Vector3(0, 0.03, 0.2)), Vector3(0.074, 0.08, 0.1), olive, 8, 5, func(d: Vector3) -> Color:
			var col: Color = skin.call(d)
			if absf(d.x) > 0.6 and d.y > 0.1 and d.y < 0.45:
				col = tan
			return col)
		# segmented abdomen, tapering
		mb.ellipsoid(Transform3D(Basis(Vector3.RIGHT, -0.08), Vector3(0, 0.0, -0.2)), Vector3(0.055, 0.06, 0.22), olive, 8, 5, func(d: Vector3) -> Color:
			var col: Color = skin.call(d)
			if fposmod(d.z * 4.5, 1.0) < 0.22:
				col = col.darkened(0.25)
			return col)
		# folded wings tented over the back
		for s in [-1.0, 1.0]:
			var b := Basis(Vector3.BACK, -0.55 * s)
			var p := PackedVector2Array([Vector2(0.0, 0.18), Vector2(0.075 * s, 0.14), Vector2(0.08 * s, -0.3), Vector2(0.03 * s, -0.45), Vector2(0.0, -0.4)])
			_slab(mb, Transform3D(b, Vector3(0, 0.075, 0)), p, 0.012, brown, brown.darkened(0.2), brown.darkened(0.3))
			for k in 3:
				mb.ellipsoid(Transform3D(b, Vector3(0.045 * s, 0.083, -0.05 - 0.11 * k)), Vector3(0.017, 0.006, 0.025), brown.darkened(0.45), 4, 2)
	)
	head = _node(body, Vector3(0, 0.02, 0.28))
	_add_mesh(head, "head", func(mb: MeshBuilder) -> void:
		mb.ellipsoid(Transform3D(Basis(Vector3.RIGHT, 0.45), Vector3(0, 0.0, 0.06)), Vector3(0.062, 0.08, 0.07), olive, 8, 5, skin)
		for s in [-1.0, 1.0]:
			mb.ellipsoid(Transform3D(Basis(), Vector3(0.05 * s, 0.035, 0.07)), Vector3(0.026, 0.036, 0.03), Color(0.3, 0.22, 0.12), 5, 3)
			var a0 := Vector3(0.022 * s, 0.05, 0.1)
			var a1 := a0 + Vector3(0.05 * s, 0.07, 0.13)
			var a2 := a1 + Vector3(0.06 * s, 0.03, 0.14)
			mb.tube(a0, a1, 0.009, 0.007, dolive, dolive, 4, false)
			mb.tube(a1, a2, 0.007, 0.004, dolive, brown, 4, false)
	)
	# hind legs: femur (big, herringbone), tibia, tarsus
	var hb := [
		func(mb: MeshBuilder) -> void:
			mb.ellipsoid(Transform3D(Basis(), Vector3(0, -0.15, 0.008)), Vector3(0.042, 0.185, 0.058), olive, 8, 6, func(d: Vector3) -> Color:
				var col: Color = skin.call(d)
				if absf(d.x) > 0.45 and fposmod(d.y * 7.0 + absf(d.z) * 2.0, 1.0) < 0.35:
					col = col.darkened(0.3)
				return col),
		func(mb: MeshBuilder) -> void:
			mb.tube(Vector3.ZERO, Vector3(0, -GH_LEN[1], 0), 0.013, 0.01, olive.lerp(Color(0.6, 0.3, 0.2), 0.4), olive, 4, false),
		func(mb: MeshBuilder) -> void:
			mb.tube(Vector3.ZERO, Vector3(0, -GH_LEN[2], 0), 0.01, 0.008, dolive, dolive, 4, false),
	]
	for i in 2:
		var s := 1.0 if i == 0 else -1.0
		var par := root
		var nodes: Array[Node3D] = []
		for k in 3:
			var n := _node(par, Vector3(0.065 * s, 0.1, 0.02) if k == 0 else Vector3(0, -GH_LEN[k - 1], 0))
			_add_mesh(n, "hleg" + str(k), hb[k])
			nodes.append(n)
			par = n
		hind.append(nodes)
	# middle & front legs: two thin segments each
	for zz in [0.1, 0.2]:
		for i in 2:
			var s := 1.0 if i == 0 else -1.0
			var a0 := _node(body, Vector3(0.04 * s, -0.04, zz))
			_add_mesh(a0, "sleg0", func(mb: MeshBuilder) -> void:
				mb.tube(Vector3.ZERO, Vector3(0, -0.1, 0), 0.012, 0.01, olive, olive, 4, false)
			)
			var a1 := _node(a0, Vector3(0, -0.1, 0))
			_add_mesh(a1, "sleg1", func(mb: MeshBuilder) -> void:
				mb.tube(Vector3.ZERO, Vector3(0, -0.09, 0), 0.01, 0.007, olive, dolive, 4, false)
			)
			fore.append([a0, a1])
			fore_base.append(Vector3(-0.45 if zz > 0.15 else 0.3, 0.0, 1.55 * s))


func _update_insect(dt: float, L: float, rs: float, spd: float, lunge: float) -> void:
	# femur, tibia, tarsus absolute pitch (from straight down, + = back)
	var rest := Vector3(1.95, -1.02, 1.5)
	var push := Vector3(1.3, 1.15, 1.5)
	var trail := Vector3(1.6, 1.5, 1.6)
	var jump := _ss(0.2, 0.45, spd / rs) if not dead else 0.0
	var D := 0.2
	var pose := rest
	var y_air := 0.0
	var pitch := 0.0
	if jump > 0.01 and move_w > 0.01:
		var q := phase
		if q < D:
			var w := _ss(0.0, 1.0, q / D)
			pose = rest.lerp(push, w)
			pitch = -0.3 * w
		else:
			var w := (q - D) / (1.0 - D)
			pose = push.lerp(trail, _ss(0.0, 0.3, w)).lerp(rest, _ss(0.55, 0.95, w))
			var hh := clampf(hop_len * 0.3, 0.3, 6.0)
			y_air = hh * 4.0 * w * (1.0 - w)
			pitch = lerpf(-0.3, 0.2, w)
		pose = rest.lerp(pose, jump * move_w)
		y_air *= jump * move_w
		pitch *= jump * move_w
	if dead_amt > 0.0:
		pose = pose.lerp(Vector3(1.4, 1.2, 1.3), dead_amt)
	# ground the lowest foot point
	var hip_y := 0.1
	var y1: float = -GH_LEN[0] * cos(pose.x)
	var y2: float = y1 - GH_LEN[1] * cos(pose.y)
	var y3: float = y2 - GH_LEN[2] * cos(pose.z)
	var low := minf(minf(0.0, y1), minf(y2, y3))
	var y_off := -(hip_y + low) + 0.01
	y_off = maxf(y_off, -0.05)
	for i in 2:
		var s := 1.0 if i == 0 else -1.0
		var nodes: Array = hind[i]
		var n0: Node3D = nodes[0]
		var n1: Node3D = nodes[1]
		var n2: Node3D = nodes[2]
		n0.rotation = Vector3(pose.x, 0.0, 0.18 * s)
		n1.rotation = Vector3(pose.y - pose.x, 0.0, 0.0)
		n2.rotation = Vector3(pose.z - pose.y, 0.0, 0.0)
	# small legs: tripod walk when not jumping
	var walk := move_w * (1.0 - jump)
	for i in fore.size():
		var arm: Array = fore[i]
		var base: Vector3 = fore_base[i]
		var a0: Node3D = arm[0]
		var a1: Node3D = arm[1]
		var ph := phase * TAU + (PI if (i % 2 == 0) != (i >= 2) else 0.0)
		var sw := sin(ph) * 0.4 * walk
		var lift := maxf(0.0, cos(ph)) * 0.4 * walk
		var tuck := jump * move_w * 0.6
		a0.rotation = base + Vector3(sw + tuck, 0.0, lift * signf(base.z))
		a1.rotation = Vector3(0.0, 0.0, -1.95 * signf(base.z) * (1.0 - dead_amt * 0.6))
	# antennae / head twitch
	twitch_timer -= dt
	if twitch_timer <= 0.0:
		twitch_timer = randf_range(0.4, 2.0)
		twitch_t = 0.2
	twitch_t = maxf(0.0, twitch_t - dt)
	var hy := sin(twitch_t * 30.0) * 0.12 * (1.0 - dead_amt)
	var hx := 0.0
	if eat_w > 0.0:
		hx = 0.2 + sin(c.action_t * 12.0) * 0.08 * eat_w
	head.rotation = Vector3(hx + lunge * 0.3, hy, 0.0)
	body_pitch = lerpf(body_pitch, pitch, 1.0 - exp(-14.0 * dt))
	body.rotation = Vector3(body_pitch, 0.0, 0.0)
	var roll := _ss(0.0, 1.0, dead_amt) * PI * 0.5
	root.position = Vector3(0.1 * sin(roll), (y_off + y_air) * (1.0 - dead_amt) + 0.07 * sin(roll), 0)
	root.rotation = Vector3(t_pitch * (1.0 - dead_amt), 0.0, roll)


# ================================================================ fish

func _build_fish() -> void:
	var back := Color(0.36, 0.4, 0.27)
	var side := Color(0.74, 0.76, 0.68)
	var bel := Color(0.92, 0.92, 0.86)
	var spot := Color(0.93, 0.43, 0.13)
	var fin := Color(0.56, 0.5, 0.32)
	var spine := Color(0.4, 0.37, 0.25)
	# t0/t1: portion of the whole fish (0 = snout, 1 = tail base) covered by a loft
	var skin := func(t0: float, t1: float, gill: bool) -> Callable:
		return func(tt: float, cs: float, sn: float) -> Color:
			var g := lerpf(t0, t1, tt)
			var col := side.lerp(back, _ss(0.2, 0.8, sn))
			col = col.lerp(bel, _ss(-0.3, -0.75, sn))
			# spangles: blocky orange-red spots on the flanks
			var cell := Vector3(floorf(g * 22.0), floorf(atan2(sn, cs) * 3.2), 0.0)
			if absf(sn) < 0.8 and g > 0.2 and _hash3(cell) > 0.7:
				col = col.lerp(spot, 0.8)
			# operculum (gill cover) edge and mouth line
			if gill and absf(g - 0.3) < 0.018 and sn < 0.6:
				col = col.darkened(0.45)
			if g < 0.06 and absf(sn) < 0.25:
				col = col.darkened(0.5)
			return _vary(col, Vector3(g * 20.0, cs, sn), 0.05)
	body = _node(root, Vector3.ZERO)
	body_mi = _add_mesh(body, "front", func(mb: MeshBuilder) -> void:
		# perch profile: blunt head, humped back
		_body(mb, [
			[0, -0.01, 0.38, 0.014, 0.016, 0.016],
			[0, 0.0, 0.34, 0.036, 0.05, 0.045],
			[0, 0.012, 0.26, 0.056, 0.095, 0.08],
			[0, 0.018, 0.15, 0.066, 0.122, 0.1],
			[0, 0.016, 0.04, 0.066, 0.122, 0.1],
			[0, 0.012, -0.05, 0.06, 0.11, 0.092],
		], 16, skin.call(0.0, 0.5, true), 3)
		for s in [-1.0, 1.0]:
			mb.ellipsoid(Transform3D(Basis(), Vector3(0.042 * s, 0.035, 0.29)), Vector3.ONE * 0.026, Color(0.88, 0.84, 0.6), 7, 4)
			mb.ellipsoid(Transform3D(Basis(), Vector3(0.057 * s, 0.036, 0.293)), Vector3(0.011, 0.016, 0.016), Color(0.02, 0.02, 0.02), 5, 3)
			# pectoral + pelvic fins
			var pb := Basis(Vector3.UP, 0.5 * s) * Basis(Vector3.BACK, 0.4 * s)
			var pp := PackedVector2Array([Vector2(0, 0.02), Vector2(0.02 * s, -0.08), Vector2(0.0, -0.1), Vector2(-0.01 * s, -0.02)])
			_slab(mb, Transform3D(pb, Vector3(0.06 * s, -0.03, 0.18)), pp, 0.006, fin, fin)
			var vb := Basis(Vector3.BACK, 0.7 * s)
			_slab(mb, Transform3D(vb, Vector3(0.03 * s, -0.1, 0.12)), PackedVector2Array([Vector2(0, 0.02), Vector2(0.01 * s, -0.08), Vector2(0.0, -0.09)]), 0.006, fin, fin)
		# spiny first dorsal: membrane + spines (outline: up, z)
		var dp := PackedVector2Array([Vector2(0.11, 0.2), Vector2(0.16, 0.17), Vector2(0.19, 0.1), Vector2(0.18, 0.03), Vector2(0.15, -0.02), Vector2(0.1, -0.04)])
		_slab(mb, Transform3D(_vfin(), Vector3.ZERO), dp, 0.006, fin.darkened(0.15), fin.darkened(0.15))
		for k in 7:
			var z := lerpf(0.19, -0.03, k / 6.0)
			var hgt := 0.21 - absf(k - 2.5) * 0.012
			mb.cone(Vector3(0, 0.11, z), Vector3(0, hgt, z - 0.015), 0.006, spine, spine.darkened(0.3), 3)
	)
	rear = _node(body, Vector3(0, 0, -0.02))
	_add_mesh(rear, "rear", func(mb: MeshBuilder) -> void:
		_body(mb, [
			[0, 0.012, 0.02, 0.062, 0.114, 0.095],
			[0, 0.008, -0.1, 0.05, 0.092, 0.078],
			[0, 0.004, -0.22, 0.032, 0.058, 0.048],
			[0, 0.0, -0.3, 0.02, 0.036, 0.03],
			[0, 0.0, -0.345, 0.014, 0.03, 0.026],
		], 14, skin.call(0.45, 1.0, false), 3, Vector3.ZERO, false)
		# soft dorsal & anal fins
		_slab(mb, Transform3D(_vfin(), Vector3.ZERO), PackedVector2Array([Vector2(0.09, 0.0), Vector2(0.16, -0.04), Vector2(0.14, -0.16), Vector2(0.04, -0.24)]), 0.006, fin, fin)
		_slab(mb, Transform3D(_vfin(), Vector3.ZERO), PackedVector2Array([Vector2(-0.08, -0.05), Vector2(-0.14, -0.1), Vector2(-0.12, -0.2), Vector2(-0.04, -0.24)]), 0.006, fin, fin)
		for k in 3:
			var z := -0.06 - k * 0.025
			mb.cone(Vector3(0, -0.08, z), Vector3(0, -0.13, z - 0.02), 0.005, spine, spine.darkened(0.3), 3)
	)
	tailfin = _node(rear, Vector3(0, 0, -0.34))
	_add_mesh(tailfin, "tail", func(mb: MeshBuilder) -> void:
		var upper := PackedVector2Array([Vector2(0.0, 0.02), Vector2(0.035, 0.01), Vector2(0.12, -0.12), Vector2(0.1, -0.145), Vector2(0.03, -0.1), Vector2(0.0, -0.07)])
		var lower := PackedVector2Array()
		for p in upper:
			lower.append(Vector2(-p.x, p.y))
		_slab(mb, Transform3D(_vfin(), Vector3.ZERO), upper, 0.007, fin, fin, fin.darkened(0.3))
		_slab(mb, Transform3D(_vfin(), Vector3.ZERO), lower, 0.007, fin, fin, fin.darkened(0.3))
		for k in 5:
			var a := lerpf(-0.9, 0.9, k / 4.0)
			mb.tube(Vector3(0, 0, 0), Vector3(0, sin(a) * 0.12, -0.1 - cos(a) * 0.02), 0.004, 0.002, fin.darkened(0.25), fin.darkened(0.25), 3, false)
	)


func _update_fish(dt: float, L: float, rs: float, spd: float, lunge: float) -> void:
	var sf := clampf(spd / rs, 0.0, 1.0)
	var alive_k := 1.0 - dead_amt
	swim_ph += dt * (5.0 + sf * 14.0) * alive_k
	var A := (0.1 + 0.3 * sf) * alive_k
	var turn := clampf(-yaw_rate * 0.12, -0.5, 0.5) * alive_k
	body.rotation = Vector3(0.0, -sin(swim_ph) * A * 0.3 + lunge * 0.0, 0.0)
	rear.rotation = Vector3(0.0, sin(swim_ph) * A + turn, 0.0)
	tailfin.rotation = Vector3(0.0, sin(swim_ph - 1.1) * A * 1.4 + turn * 0.6 + 0.15 * dead_amt, 0.0)
	var bob := sin(t * 1.4) * 0.01 * alive_k
	var roll := _ss(0.0, 1.0, dead_amt) * PI * 0.5
	root.position = Vector3(0, bob + 0.07 * sin(roll), lunge * 0.05)
	root.rotation = Vector3(0.0, 0.0, roll)


# ================================================================ update

func update_rig(dt: float) -> void:
	if c == null or dt <= 0.0:
		return
	dt = minf(dt, 0.1)
	t += dt
	var L := maxf(c.length, 0.001)
	var ws := maxf(0.01, c.walk_speed())
	var rs := maxf(ws + 0.01, c.run_speed())
	var spd := 0.0 if dead else c.speed
	move_w = lerpf(move_w, clampf(spd / (ws * 0.5), 0.0, 1.0), 1.0 - exp(-10.0 * dt))
	run_w = lerpf(run_w, clampf((spd - ws) / (rs - ws), 0.0, 1.0), 1.0 - exp(-6.0 * dt))
	eat_w = move_toward(eat_w, 1.0 if (c.action == "eat" or c.action == "drink") and not dead else 0.0, dt * 4.0)
	if dead:
		dead_amt = move_toward(dead_amt, 1.0, dt * 2.5)
	yaw_rate = lerpf(yaw_rate, wrapf(c.yaw - _prev_yaw, -PI, PI) / dt, 1.0 - exp(-8.0 * dt))
	_prev_yaw = c.yaw
	# hop cycle length from speed: roughly constant hop frequency
	var dg := c.gait_phase - _last_gp
	_last_gp = c.gait_phase
	if dg < 0.0 or dg > 4.0:
		dg = 0.0
	var f_hop := lerpf(2.5, 4.0, run_w) if kind == "frog" else lerpf(1.5, 2.5, run_w)
	hop_len = maxf(1.2, spd / L / f_hop)
	if kind != "fish":
		phase = fposmod(phase + dg * c.stride() / L / hop_len, 1.0)
		if move_w < 0.02:
			phase = 0.0 if phase < 0.5 else move_toward(phase, 1.0, dt * 2.0)
			if phase >= 1.0:
				phase = 0.0
	# terrain pitch
	if kind != "fish" and not dead and not c.swimming:
		var fw := c.fwd()
		var hf := c.terrain.height(c.position.x + fw.x * L * 0.4, c.position.z + fw.z * L * 0.4)
		var hb := c.terrain.height(c.position.x - fw.x * L * 0.4, c.position.z - fw.z * L * 0.4)
		t_pitch = lerpf(t_pitch, clampf(-atan2(hf - hb, L * 0.8), -0.6, 0.6), 1.0 - exp(-6.0 * dt))
	var lunge := 0.0
	if bite_t >= 0.0:
		bite_t += dt
		var bk := bite_t / maxf(0.15, c.action_len if c.action_len > 0.0 else 0.4)
		lunge = sin(clampf(bk, 0.0, 1.0) * PI)
		if bk >= 1.0:
			bite_t = -1.0
	hit_t = maxf(0.0, hit_t - dt)
	match kind:
		"fish":
			_update_fish(dt, L, rs, spd, lunge)
		"insect":
			_update_insect(dt, L, rs, spd, lunge)
		_:
			_update_frog(dt, L, rs, spd, lunge)
	if hit_t > 0.0 or c.flinch > 0.0:
		var j := sin(hit_t * 45.0) * hit_t * 0.4 + c.flinch * 0.1
		root.rotation.z += j * 0.4
		root.rotation.x -= j * 0.3
