class_name ReptileRig
extends Node3D
## Procedural reptile body (monitors, crocodiles, skinks).
## - A follow-the-leader spine chain gives the long body and trailing tail.
## - The body is lofted every frame with an anatomical cross-section (dorsal
##   ridge, broad flanks, flat belly, keeled compressed tail); normals are
##   computed from the actual geometry.
## - Limbs grow out of the flanks: near-horizontal upper arm/thigh, vertical
##   forearm/shin, flat hand with five clawed toes (two-bone IK).
## - Diagonal-couplet gait whose phase is locked to distance travelled, so
##   feet stay planted while the body swings over them in an S-wave.
## - Separate skull + hinged lower jaw (ReptileHead) and a flicking tongue.

var c: Creature
var mi := MeshInstance3D.new()
var mesh := ArrayMesh.new()
var tongue := MeshInstance3D.new()
var head_mi := MeshInstance3D.new()
var jaw_mi := MeshInstance3D.new()

# Body profile per chain point: t along body (0 snout .. 1 tail tip), half-width & half-height (fraction of L)
var prof_t := PackedFloat32Array()
var prof_w := PackedFloat32Array()
var prof_h := PackedFloat32Array()
var seg_len := PackedFloat32Array()
var stiff := PackedFloat32Array()
var n_pts := 0
var shoulder_i := 6
var pelvis_i := 10
var head_base_i := 3
var leg_upper := 0.07
var leg_lower := 0.065
var leg_r := 0.02
var clearance := 0.03
var head_up := 0.02
var toes := 5
var base_col := Color()
var spot_col := Color()
var belly_col := Color()
var pattern := "monitor"

var pts := PackedVector3Array()           # simulated chain (world)
var ys := PackedFloat32Array()
var vis := PackedVector3Array()           # chain with visual offsets applied
var pt_up := PackedVector3Array()         # body "up" per chain point (world up, or away from a tree trunk)
var climb_mode := false

# legs: 0 FL, 1 FR, 2 RL, 3 RR
var foot := [Vector3(), Vector3(), Vector3(), Vector3()]
var foot_from := [Vector3(), Vector3(), Vector3(), Vector3()]
var swinging := [false, false, false, false]
var swing_t := [0.0, 0.0, 0.0, 0.0]
const LEG_PHASE := [0.0, 0.5, 0.5, 0.0]
var cycle := 0.0
var _last_sh := Vector3.INF
var _last_yaw := 0.0

var head_yaw := 0.0
var head_pitch := 0.0
var look_timer := 0.0
var look_goal := 0.0
var tongue_t := 0.0
var tongue_timer := 2.0
var hit_t := 0.0
var whip_t := -1.0
var bite_t := -1.0
var dead := false
var roll := 0.0
var swim_phase := 0.0
var breath := 0.0
var jaw_angle := 0.0

var ring_cols: PackedColorArray
var ring_uvs := PackedVector2Array()
var ring_count := 0
var rv := 14
var sub := 3
var indices := PackedInt32Array()
var lod_level := -1
var _mat: ShaderMaterial
var debug_legs := false
static var _skin_shader: Shader

# skinned model (Blender-authored mesh driven by the same procedural pose)
var skinned := false
var skin_root: Node3D
var skel: Skeleton3D
var skin_order: Array = []        # bone indices, parents first
var skin_parent := {}             # idx -> parent idx driven by us (or -1)
var skin_name := {}               # idx -> bone name
var bone_rest := {}               # idx -> global rest Transform3D
var rest_frames := {}             # name -> Transform3D (normalised rest frame)
var leg_hip := [Vector3(), Vector3(), Vector3(), Vector3()]
var leg_knee := [Vector3(), Vector3(), Vector3(), Vector3()]
var leg_wrist := [Vector3(), Vector3(), Vector3(), Vector3()]
var leg_toe := [Vector3(), Vector3(), Vector3(), Vector3()]
var leg_up := [Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP]
static var _skin_cache := {}


func setup(creature: Creature) -> void:
	c = creature
	_define_species()
	_try_skin()
	mi.mesh = mesh
	mi.top_level = true
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if _skin_shader == null:
		_skin_shader = load("res://assets/shaders/reptile_skin.gdshader")
	_mat = ShaderMaterial.new()
	_mat.shader = _skin_shader
	_mat.set_shader_parameter("gloss", 0.55 if c.species_id == "skink" else 0.3)
	if c.species_id == "croc":
		_mat.set_shader_parameter("scale_count", Vector2(70.0, 18.0))
	mi.material_override = _mat
	add_child(mi)
	if not skinned:
		var hm: Array = ReptileHead.get_meshes(c.species_id, base_col, spot_col, belly_col)
		head_mi.mesh = hm[0]
		head_mi.material_override = _mat
		jaw_mi.mesh = hm[1]
		jaw_mi.material_override = _mat
	else:
		mi.visible = false
	head_mi.top_level = true
	add_child(head_mi)
	head_mi.add_child(jaw_mi)
	tongue.mesh = _tongue_mesh()
	tongue.top_level = true
	tongue.visible = false
	var tm := StandardMaterial3D.new()
	tm.albedo_color = Color(0.5, 0.22, 0.34)
	tm.roughness = 0.35
	tongue.material_override = tm
	add_child(tongue)
	_set_lod(0)
	reset_chain()


func _define_species() -> void:
	match c.species_id:
		"croc":
			prof_t = PackedFloat32Array([0.0, 0.05, 0.1, 0.14, 0.18, 0.22, 0.29, 0.36, 0.43, 0.5, 0.58, 0.67, 0.76, 0.85, 0.93, 1.0])
			prof_w = PackedFloat32Array([0.018, 0.028, 0.036, 0.05, 0.055, 0.07, 0.085, 0.088, 0.075, 0.052, 0.04, 0.03, 0.022, 0.014, 0.008, 0.002])
			prof_h = PackedFloat32Array([0.01, 0.015, 0.02, 0.03, 0.04, 0.048, 0.054, 0.055, 0.05, 0.05, 0.046, 0.04, 0.032, 0.024, 0.014, 0.004])
			shoulder_i = 5
			pelvis_i = 8
			head_base_i = 4
			leg_upper = 0.055
			leg_lower = 0.048
			leg_r = 0.027
			clearance = 0.02
			head_up = 0.0
			base_col = Color(0.2, 0.22, 0.14)
			spot_col = Color(0.08, 0.09, 0.06)
			belly_col = Color(0.65, 0.6, 0.45)
			pattern = "croc"
		"skink":
			prof_t = PackedFloat32Array([0.0, 0.03, 0.07, 0.1, 0.14, 0.2, 0.28, 0.36, 0.44, 0.52, 0.62, 0.72, 0.82, 0.91, 1.0])
			prof_w = PackedFloat32Array([0.02, 0.04, 0.05, 0.05, 0.058, 0.066, 0.07, 0.07, 0.066, 0.058, 0.045, 0.034, 0.022, 0.012, 0.003])
			prof_h = PackedFloat32Array([0.015, 0.03, 0.04, 0.045, 0.05, 0.054, 0.056, 0.056, 0.052, 0.05, 0.04, 0.03, 0.02, 0.012, 0.003])
			shoulder_i = 4
			pelvis_i = 8
			head_base_i = 2
			leg_upper = 0.045
			leg_lower = 0.04
			leg_r = 0.016
			clearance = 0.012
			head_up = 0.01
			base_col = Color(0.42, 0.32, 0.2)
			spot_col = Color(0.12, 0.09, 0.06)
			belly_col = Color(0.75, 0.7, 0.55)
			pattern = "skink"
		_:
			# lace monitor: long neck, heavy mid-body, very long whip-like tail
			prof_t = PackedFloat32Array([0.0, 0.03, 0.065, 0.1, 0.135, 0.17, 0.215, 0.26, 0.31, 0.36, 0.41, 0.46, 0.52, 0.6, 0.69, 0.79, 0.89, 1.0])
			prof_w = PackedFloat32Array([0.011, 0.022, 0.03, 0.031, 0.03, 0.033, 0.047, 0.06, 0.066, 0.064, 0.055, 0.041, 0.031, 0.024, 0.018, 0.012, 0.007, 0.0015])
			prof_h = PackedFloat32Array([0.008, 0.017, 0.025, 0.029, 0.03, 0.032, 0.039, 0.045, 0.048, 0.046, 0.042, 0.038, 0.033, 0.028, 0.022, 0.015, 0.008, 0.0015])
			shoulder_i = 6
			pelvis_i = 10
			head_base_i = 3
			leg_upper = 0.072
			leg_lower = 0.066
			leg_r = 0.018
			clearance = 0.026
			head_up = 0.024
			base_col = Color(0.11, 0.105, 0.1)
			spot_col = Color(0.78, 0.7, 0.46)
			belly_col = Color(0.62, 0.56, 0.4)
			pattern = "monitor"
	# the tube inside the skull is hidden by the head mesh
	for i in head_base_i:
		prof_w[i] *= 0.45
		prof_h[i] *= 0.45
	n_pts = prof_t.size()
	seg_len.resize(n_pts)
	stiff.resize(n_pts)
	for i in n_pts:
		seg_len[i] = 0.0 if i == 0 else prof_t[i] - prof_t[i - 1]
		if i <= shoulder_i:
			stiff[i] = 0.0
		elif i <= pelvis_i:
			stiff[i] = 0.6
		else:
			stiff[i] = lerpf(0.4, 0.1, float(i - pelvis_i) / (n_pts - pelvis_i))
	pts.resize(n_pts)
	ys.resize(n_pts)
	vis.resize(n_pts)
	pt_up.resize(n_pts)
	pt_up.fill(Vector3.UP)


static var _lod_cache := {}


func _set_lod(level: int) -> void:
	if level == lod_level:
		return
	lod_level = level
	rv = (14 if c.is_player else 12) if level == 0 else 7
	sub = (3 if c.is_player else 2) if level == 0 else 1
	if c.species_id == "skink":
		rv = 7
		sub = 1
	ring_count = (n_pts - 1) * sub + 1
	var key := "%s_%d_%d_%d" % [c.species_id, rv, sub, int(clampf(1.0 - c.size * 1.6, 0.0, 1.0) * 4.0)]
	if _lod_cache.has(key):
		var e: Array = _lod_cache[key]
		ring_cols = e[0]
		ring_uvs = e[1]
		indices = e[2]
		return
	ring_cols = PackedColorArray()
	ring_cols.resize(ring_count * rv)
	ring_uvs = PackedVector2Array()
	ring_uvs.resize(ring_count * rv)
	for r in ring_count:
		var t := _ring_t(r)
		for k in rv:
			var th := TAU * k / rv
			ring_cols[r * rv + k] = _skin_color(t, th, k)
			ring_uvs[r * rv + k] = Vector2(0.002 + t, float(k) / rv)
	indices = PackedInt32Array()
	for r in ring_count - 1:
		for k in rv:
			var a := r * rv + k
			var b := r * rv + (k + 1) % rv
			var a2 := a + rv
			var b2 := b + rv
			indices.append_array([a, b, b2, a, b2, a2])
	_lod_cache[key] = [ring_cols, ring_uvs, indices]


func _ring_t(r: int) -> float:
	var seg := r / sub
	var f := float(r % sub) / sub
	if seg >= n_pts - 1:
		return 1.0
	return lerpf(prof_t[seg], prof_t[seg + 1], f)


static func _hash(a: float, b: float) -> float:
	return absf(fmod(sin(a * 12.9898 + b * 78.233) * 43758.5453, 1.0))


func _skin_color(t: float, th: float, k: int) -> Color:
	var up := sin(th)
	var side := cos(th)
	var col := base_col
	var juvenile := clampf(1.0 - c.size * 1.6, 0.0, 1.0) if c.species_id == "monitor" else 0.0
	match pattern:
		"monitor":
			var sc := spot_col.lerp(Color(0.92, 0.84, 0.52), juvenile * 0.5)
			var h := _hash(float(k), floor(t * 70.0))
			if t < 0.1:
				pass
			elif t < 0.46:
				# rows of pale spots forming broken bands, fine flecks between
				var band := fmod(t * 19.0, 1.0)
				if band < 0.4 and up > -0.4:
					col = sc if h > 0.35 else base_col.lerp(sc, 0.3)
				elif h > 0.88 and up > -0.1:
					col = sc.darkened(0.2)
			else:
				var tb := fmod((t - 0.46) * 14.0, 1.0)
				if tb < 0.36 and up > -0.75:
					col = sc.darkened(0.12) if h > 0.2 else sc.darkened(0.4)
			if up < -0.5:
				col = belly_col.lerp(col, 0.35)
		"croc":
			var band2 := fmod(t * 18.0, 1.0)
			if band2 < 0.3 and up > 0.2 and t > 0.2:
				col = spot_col
			if up > 0.6 and t > 0.15 and t < 0.6 and (k % 2 == 0):
				col = col.darkened(0.25)
			if up < -0.3:
				col = belly_col
		"skink":
			if absf(side) > 0.55 and up > -0.3:
				col = spot_col
			elif up > 0.75:
				col = base_col.lightened(0.25)
			if up < -0.4:
				col = belly_col
	return col


func _tongue_mesh() -> ArrayMesh:
	var mb := MeshBuilder.new()
	var col := Color(1, 1, 1)
	mb.tube(Vector3(0, 0, 0), Vector3(0, 0, 0.6), 0.05, 0.035, col, col, 5, false)
	mb.tube(Vector3(0, 0, 0.6), Vector3(0.14, 0, 1.0), 0.035, 0.008, col, col, 4, true)
	mb.tube(Vector3(0, 0, 0.6), Vector3(-0.14, 0, 1.0), 0.035, 0.008, col, col, 4, true)
	return mb.commit()


func reset_chain() -> void:
	var L := c.length
	var f := c.fwd()
	var origin := c.position
	var d_sh := prof_t[shoulder_i]
	for i in n_pts:
		var along := (d_sh - prof_t[i]) * L
		var p := origin + f * along
		p.y = c.terrain.height(p.x, p.z) + prof_h[i] * L * 0.6
		pts[i] = p
		ys[i] = p.y
		vis[i] = p
		pt_up[i] = Vector3.UP
	for k in 4:
		foot[k] = _foot_rest(k, f)
		swinging[k] = false
	_last_sh = c.position
	_last_yaw = c.yaw


func on_resize() -> void:
	var lv := lod_level
	lod_level = -1
	_set_lod(maxi(lv, 0))
	reset_chain()


func on_action(a: String) -> void:
	if a == "bite":
		bite_t = 0.0
	elif a == "whip":
		whip_t = 0.0


func on_hit() -> void:
	hit_t = 0.3


func on_death() -> void:
	dead = true


# ------------------------------------------------------------------ update

func update_rig(dt: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var dcam := cam.global_position.distance_to(c.position)
		var near_d := 1.5 + c.length * 4.5
		if lod_level == 0:
			near_d *= 1.3
		_set_lod(0 if (c.is_player or dcam < near_d) else 1)
	var L := c.length
	var f := c.fwd()
	var terr := c.terrain
	var moving := clampf(c.speed / maxf(0.01, c.walk_speed()), 0.0, 2.0)
	var run_frac := clampf((c.speed - c.walk_speed()) / maxf(0.01, c.run_speed() - c.walk_speed()), 0.0, 1.0)
	breath += dt * (1.2 if c.speed < 0.1 else 3.0)
	# ---- gait phase from distance travelled (+ turning in place)
	var sh := c.position
	if _last_sh == Vector3.INF or sh.distance_to(_last_sh) > L * 1.5 + 1.0:
		reset_chain()
	var moved := Vector2(sh.x - _last_sh.x, sh.z - _last_sh.z).length()
	moved += absf(wrapf(c.yaw - _last_yaw, -PI, PI)) * L * 0.18
	_last_sh = sh
	_last_yaw = c.yaw
	var cycle_dist := L * (0.36 + 0.16 * run_frac)
	if not dead and not c.swimming:
		cycle += moved / cycle_dist
	if c.climbing:
		_update_climb_chain(dt, L)
		climb_mode = true
		roll = 0.0
		_build_mesh(L, dt, Vector3.UP, 0.0)
		return
	if climb_mode:
		climb_mode = false
		pt_up.fill(Vector3.UP)
	# ---- head animation targets
	look_timer -= dt
	if look_timer <= 0.0:
		look_timer = randf_range(1.5, 4.0)
		look_goal = randf_range(-0.55, 0.55) if moving < 0.2 else 0.0
	var tgt_yaw := look_goal
	var tgt_pitch := 0.0
	if c.brain != null:
		var lp = c.brain.get("look_point")
		if lp is Vector3:
			var dl: Vector3 = lp - c.position
			tgt_yaw = clampf(wrapf(atan2(dl.x, dl.z) - c.yaw, -PI, PI), -0.9, 0.9)
	if moving > 0.2:
		# monitors swing the head against the body wave
		tgt_yaw += -sin(cycle * TAU) * 0.12 * clampf(moving, 0.0, 1.0)
	if c.action == "eat" or c.action == "drink":
		tgt_pitch = -0.55 + sin(c.action_t * (9.0 if c.action == "eat" else 5.0)) * 0.15
		tgt_yaw = sin(c.action_t * 3.0) * 0.15
	if c.posture_amt > 0.01:
		tgt_pitch = lerpf(tgt_pitch, 0.35, c.posture_amt)
	if c.swimming:
		tgt_pitch = 0.15
	if c.rest_amt > 0.5:
		tgt_pitch = -0.1
	head_yaw = lerpf(head_yaw, tgt_yaw, 1.0 - exp(-4.0 * dt))
	head_pitch = lerpf(head_pitch, tgt_pitch, 1.0 - exp(-6.0 * dt))
	# ---- head/neck forward from the shoulder
	pts[shoulder_i] = sh
	var neck_ext := 1.0
	if bite_t >= 0.0:
		bite_t += dt
		var bk := bite_t / maxf(0.2, c.action_len)
		neck_ext = 1.0 + 0.35 * sin(clampf(bk, 0.0, 1.0) * PI) - 0.15 * (1.0 - smoothstep(0.0, 0.25, bk))
		if bk >= 1.0:
			bite_t = -1.0
	var acc_yaw := 0.0
	for i in range(shoulder_i - 1, -1, -1):
		acc_yaw += head_yaw / shoulder_i
		var dir := f.rotated(Vector3.UP, acc_yaw)
		pts[i] = pts[i + 1] + dir * seg_len[i + 1] * L * neck_ext
	# ---- torso & tail follow the leader
	for i in range(shoulder_i + 1, n_pts):
		var prev: Vector3 = pts[i - 1]
		var d := pts[i] - prev
		d.y = 0
		var dl2 := d.length()
		var dir2 := d / dl2 if dl2 > 0.0001 else -f
		var parent_dir := -f
		if i > shoulder_i + 1:
			parent_dir = pts[i - 1] - pts[i - 2]
			parent_dir.y = 0
			parent_dir = parent_dir.normalized() if parent_dir.length_squared() > 0.000001 else -f
		dir2 = dir2.lerp(parent_dir, stiff[i]).normalized()
		pts[i] = prev + dir2 * seg_len[i] * L
	# ---- lateral S-wave (visual), whip, flinch
	var gait := clampf(moving, 0.0, 1.3)
	var ph := cycle * TAU
	if c.swimming:
		swim_phase += dt * (3.0 + c.speed * 2.0 / maxf(0.2, L))
		ph = swim_phase
		gait = 1.2
	var whip_off := 0.0
	if whip_t >= 0.0:
		whip_t += dt
		whip_off = sin(clampf(whip_t / 0.6, 0.0, 1.0) * PI) * (1.0 if int(c.id) % 2 == 0 else -1.0)
		if whip_t > 0.6:
			whip_t = -1.0
	if hit_t > 0.0:
		hit_t -= dt
	var amp := (0.035 + 0.02 * run_frac) * gait
	for i in n_pts:
		var t2 := prof_t[i]
		var lat := 0.0
		if not dead:
			if c.swimming:
				lat = sin(ph - t2 * 7.0) * 0.07 * smoothstep(0.2, 1.0, t2) * (1.0 + t2) * L
			else:
				# standing wave on the trunk (girdles swing opposite) + travelling wave in the tail
				var trunk := sin(ph) * cos((t2 - prof_t[shoulder_i]) / (prof_t[pelvis_i] - prof_t[shoulder_i]) * PI)
				var tailw := sin(ph - (t2 - prof_t[pelvis_i]) * 9.0) * smoothstep(prof_t[pelvis_i], 1.0, t2) * 1.6
				lat = (trunk * (1.0 - smoothstep(prof_t[pelvis_i], prof_t[pelvis_i] + 0.1, t2)) + tailw) * amp * L
			if c.speed < 0.05 and not c.swimming:
				lat += sin(breath * 0.4 - t2 * 4.0) * 0.01 * L * smoothstep(0.5, 1.0, t2)
			if c.posture_amt > 0.0 and t2 > 0.45:
				lat += sin((t2 - 0.45) * 9.0) * 0.08 * L * c.posture_amt
			lat += whip_off * 0.45 * L * smoothstep(0.42, 1.0, t2) * t2
			lat -= whip_off * 0.05 * L * (1.0 - t2)
			if hit_t > 0.0:
				lat += sin(t2 * 20.0 + hit_t * 60.0) * 0.02 * L * hit_t * 3.0
		else:
			lat = sin(t2 * 5.0 + float(c.id)) * 0.08 * L * smoothstep(0.4, 1.0, t2)
		vis[i] = pts[i] + _seg_side_pts(i) * lat
	# ---- vertical placement on visual positions (never below the ground)
	var submerge := c.swimming
	var lift := clearance * L * (1.0 - c.rest_amt * 0.9) * (1.0 + c.posture_amt * 1.2)
	if dead:
		lift = 0.0
	for i in n_pts:
		var p: Vector3 = vis[i]
		var hh := prof_h[i] * L
		var ww := prof_w[i] * L
		var sd := _seg_side_pts(i)
		var gy := maxf(terr.height(p.x, p.z), maxf(terr.height(p.x + sd.x * ww, p.z + sd.z * ww), terr.height(p.x - sd.x * ww, p.z - sd.z * ww)))
		var belly := hh * 0.62
		var y: float
		if submerge:
			y = -hh * 0.35
			if i < shoulder_i:
				y = -hh * 0.1 + head_up * L * 0.5
			if c.species_id == "croc" and c.brain != null and c.brain.get("submerged") == true:
				y = -hh * (0.9 if i >= 3 else 0.55)
			y = maxf(y, gy + belly)
		else:
			var l2 := lift
			if i > pelvis_i:
				l2 *= clampf(1.0 - float(i - pelvis_i) / 3.0, 0.0, 1.0)
			y = gy + belly + l2
			if i < shoulder_i:
				var fr := float(shoulder_i - i) / shoulder_i
				y += head_up * L * fr * (1.0 - c.rest_amt * 0.7)
				y += sin(head_pitch) * (prof_t[shoulder_i] - prof_t[i]) * L * 1.2
				y += c.posture_amt * L * 0.06 * fr
		var cur: float = ys[i]
		cur = lerpf(cur, y, 1.0 - exp(-25.0 * dt)) if not dead else y
		cur = maxf(cur, gy + belly * 0.85)
		ys[i] = cur
		vis[i].y = cur
		pts[i].y = cur
	roll = lerpf(roll, 1.9 if dead else 0.0, 1.0 - exp(-3.0 * dt))
	_build_mesh(L, dt, f, run_frac)


func _update_climb_chain(dt: float, L: float) -> void:
	var t: Dictionary = c.climb_tree
	var base_y: float = c.terrain.hmap(t.p.x, t.p.y)
	var center := Vector3(t.p.x, base_y, t.p.y)
	var radial := Vector3(cos(c.climb_ang), 0.0, sin(c.climb_ang))
	var tside := radial.cross(Vector3.UP).normalized()
	var ph := cycle * TAU
	cycle += c.speed * dt / maxf(0.05, L * 0.36)
	breath += dt
	head_yaw = lerpf(head_yaw, 0.0, 1.0 - exp(-4.0 * dt))
	for i in n_pts:
		var s := (prof_t[shoulder_i] - prof_t[i]) * L
		var y := c.climb_h + s
		var hh := prof_h[i] * L
		var p: Vector3
		var up := radial
		if y >= 0.0:
			var R := Terrain.trunk_radius(t, y)
			p = center + radial * (R + hh * 0.62) + Vector3.UP * y
			if y < hh * 2.0:
				up = radial.lerp(Vector3.UP, 1.0 - y / (hh * 2.0)).normalized()
		else:
			var extra := -y
			var q: Vector3 = center + radial * (t.r0 + hh * 0.6 + extra)
			q.y = c.terrain.height(q.x, q.z) + hh * 0.62
			p = q
			up = Vector3.UP
		# gentle S-wave along the trunk while moving
		var lat := sin(ph - prof_t[i] * 7.0) * 0.03 * L * clampf(c.speed * 3.0, 0.0, 1.0) * smoothstep(0.1, 0.6, prof_t[i])
		lat += sin(breath * 0.5 - prof_t[i] * 5.0) * 0.01 * L * smoothstep(0.5, 1.0, prof_t[i])
		p += tside * lat
		pts[i] = p
		vis[i] = p
		ys[i] = p.y
		pt_up[i] = up


func _seg_side_pts(i: int) -> Vector3:
	var a: Vector3 = pts[max(i - 1, 0)]
	var b: Vector3 = pts[min(i + 1, n_pts - 1)]
	var d := a - b
	d.y = 0
	if d.length_squared() < 0.0000001:
		var ff := c.fwd()
		return Vector3(ff.z, 0, -ff.x)
	d = d.normalized()
	return Vector3(d.z, 0, -d.x)


func _vis_side(i: int) -> Vector3:
	var a: Vector3 = vis[max(i - 1, 0)]
	var b: Vector3 = vis[min(i + 1, n_pts - 1)]
	var d := a - b
	if not climb_mode:
		d.y = 0
	if d.length_squared() < 0.0000001:
		var ff := c.fwd()
		return Vector3(ff.z, 0, -ff.x)
	var sd: Vector3 = pt_up[i].cross(d.normalized())
	if sd.length_squared() < 0.000001:
		var ff2 := c.fwd()
		return Vector3(ff2.z, 0, -ff2.x)
	return sd.normalized()


func _catmull3(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)


## Cross-section offset for angle th at body position t (w, h = half extents).
func _section(t: float, cs: float, sn: float, w: float, h: float) -> Vector2:
	var x := cs * w
	var y: float
	if sn >= 0.0:
		# rounded back with a slight dorsal ridge
		y = sn * h * (1.0 + 0.08 * pow(sn, 6.0))
		x *= 1.0 + 0.07 * (1.0 - sn)   # broad flanks
	else:
		y = sn * h * 0.62               # flat belly
		x *= 1.0 + 0.1 * (-sn) * (1.0 - absf(cs)) * 0.0 + 0.05 * (1.0 + sn)
	if t > prof_t[pelvis_i] + 0.03:
		# laterally compressed, keeled tail
		var tail := smoothstep(prof_t[pelvis_i] + 0.03, prof_t[pelvis_i] + 0.2, t)
		x *= 1.0 - 0.28 * tail
		if sn > 0.0:
			y *= 1.0 + 0.3 * tail * pow(sn, 8.0)
	return Vector2(x, y)


func _build_mesh(L: float, dt: float, f: Vector3, run_frac: float) -> void:
	if skinned:
		_pose_skin(L, dt, f, run_frac)
		return
	var nv := ring_count * rv
	var verts := PackedVector3Array()
	verts.resize(nv)
	var centers := PackedVector3Array()
	centers.resize(ring_count)
	var frames_up := PackedVector3Array()
	frames_up.resize(ring_count)
	var frames_sd := PackedVector3Array()
	frames_sd.resize(ring_count)
	var widths := PackedFloat32Array()
	var heights := PackedFloat32Array()
	var ts := PackedFloat32Array()
	widths.resize(ring_count)
	heights.resize(ring_count)
	ts.resize(ring_count)
	var breath_s := 1.0 + sin(breath) * 0.03
	var sh_t := prof_t[shoulder_i]
	var pv_t := prof_t[pelvis_i]
	for r in ring_count:
		var seg := mini(r / sub, n_pts - 2)
		var fr := float(r - seg * sub) / sub
		if r == ring_count - 1:
			seg = n_pts - 2
			fr = 1.0
		var p0: Vector3 = vis[max(seg - 1, 0)]
		var p1: Vector3 = vis[seg]
		var p2: Vector3 = vis[seg + 1]
		var p3: Vector3 = vis[min(seg + 2, n_pts - 1)]
		centers[r] = _catmull3(p0, p1, p2, p3, fr) if sub > 1 else p1.lerp(p2, fr)
		var w := lerpf(prof_w[seg], prof_w[seg + 1], fr) * L
		var hh := lerpf(prof_h[seg], prof_h[seg + 1], fr) * L
		var t := lerpf(prof_t[seg], prof_t[seg + 1], fr)
		ts[r] = t
		if t > sh_t - 0.02 and t < pv_t:
			w *= breath_s
		# shoulder and hip girdle bulges where the limbs attach
		w *= 1.0 + 0.1 * exp(-pow((t - sh_t) / 0.025, 2.0)) + 0.12 * exp(-pow((t - pv_t) / 0.025, 2.0))
		if c.posture_amt > 0.0:
			if t > 0.08 and t < sh_t + 0.03:
				hh *= 1.0 + 0.45 * c.posture_amt   # inflated throat
			if t > sh_t and t < pv_t + 0.05:
				w *= 1.0 - 0.18 * c.posture_amt
				hh *= 1.0 + 0.3 * c.posture_amt
		widths[r] = w
		heights[r] = hh
	var roll_c := cos(roll)
	var roll_s := sin(roll)
	var vi := 0
	for r in ring_count:
		var a: Vector3 = centers[max(r - 1, 0)]
		var b: Vector3 = centers[min(r + 1, ring_count - 1)]
		var tan := a - b
		if tan.length_squared() < 1e-12:
			tan = f
		tan = tan.normalized()
		var seg_u := mini(r / sub, n_pts - 2)
		var ref_up: Vector3 = pt_up[seg_u].lerp(pt_up[seg_u + 1], clampf(float(r - seg_u * sub) / sub, 0.0, 1.0))
		var up0 := (ref_up - tan * tan.dot(ref_up)).normalized()
		var sd := up0.cross(tan).normalized()
		var up := up0 * roll_c + sd * roll_s
		sd = up.cross(tan).normalized()
		frames_up[r] = up
		frames_sd[r] = sd
		var w2: float = widths[r]
		var h2: float = heights[r]
		var cen: Vector3 = centers[r]
		var t3: float = ts[r]
		for k in rv:
			var th := TAU * k / rv
			var o := _section(t3, cos(th), sin(th), w2, h2)
			verts[vi] = cen + sd * o.x + up * o.y
			vi += 1
	# normals from the actual surface
	var norms := PackedVector3Array()
	norms.resize(nv)
	for r in ring_count:
		var rp := maxi(r - 1, 0)
		var rn := mini(r + 1, ring_count - 1)
		for k in rv:
			var kp := (k + rv - 1) % rv
			var kn := (k + 1) % rv
			var along: Vector3 = verts[rp * rv + k] - verts[rn * rv + k]
			var around: Vector3 = verts[r * rv + kn] - verts[r * rv + kp]
			var n := around.cross(along)
			if n.length_squared() < 1e-14:
				n = verts[r * rv + k] - centers[r]
			norms[r * rv + k] = n.normalized()
	var cols := ring_cols.duplicate()
	var uvs := ring_uvs.duplicate()
	var idx := indices.duplicate()
	_update_legs(dt, verts, norms, cols, uvs, idx, L, run_frac)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	mesh.clear_surfaces()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	# ---- head & jaw
	var hb := head_base_i
	var hpos: Vector3 = vis[hb]
	var hdir: Vector3 = vis[0] - hpos
	var hl := maxf(hdir.length(), 0.0005)
	hdir /= hl
	var href: Vector3 = pt_up[hb]
	var hup := (href - hdir * hdir.dot(href)).normalized()
	var hsd := hup.cross(hdir).normalized()
	hup = hup * roll_c + hsd * roll_s
	hsd = hup.cross(hdir).normalized()
	head_mi.global_transform = Transform3D(Basis(hsd * hl, hup * hl, hdir * hl), hpos - hup * prof_h[hb] * L * 0.2)
	var want_jaw := 0.0
	if bite_t >= 0.0:
		var bk := bite_t / maxf(0.2, c.action_len)
		want_jaw = 0.75 * (1.0 - smoothstep(0.25, 0.38, bk)) * smoothstep(0.0, 0.12, bk)
	elif c.posture_amt > 0.05:
		want_jaw = 0.45 * c.posture_amt + sin(breath * 3.0) * 0.05
	elif c.action == "eat":
		want_jaw = 0.18 + 0.18 * sin(c.action_t * 9.0)
	elif c.action == "drink":
		want_jaw = 0.08 + 0.06 * sin(c.action_t * 6.0)
	elif dead:
		want_jaw = 0.25
	elif c.species_id == "croc" and c.brain != null and c.brain.get("state") == "bask":
		want_jaw = 0.5
	jaw_angle = lerpf(jaw_angle, want_jaw, 1.0 - exp(-(30.0 if want_jaw > jaw_angle else 22.0) * dt))
	jaw_mi.transform = Transform3D(Basis(Vector3.RIGHT, jaw_angle), Vector3(0, 0, 0.04))
	_update_tongue(dt, head_mi.global_transform * Vector3(0, 0.0, 0.97), hdir, L)


# ------------------------------------------------------------------ skinned model

func _try_skin() -> void:
	var sid := c.species_id
	var path := "res://assets/creatures/%s.glb" % sid
	var jpath := "res://assets/creatures/%s.rig.json" % sid
	if not ResourceLoader.exists(path) or not FileAccess.file_exists(jpath):
		return
	if not _skin_cache.has(sid):
		var js = JSON.parse_string(FileAccess.get_file_as_string(jpath))
		var frames := {}
		if typeof(js) == TYPE_DICTIONARY:
			var fr: Dictionary = js.get("frames", {})
			for k in fr.keys():
				var e: Dictionary = fr[k]
				var o := Vector3(e.o[0], e.o[1], e.o[2])
				var d := Vector3(e.d[0], e.d[1], e.d[2])
				var u := Vector3(e.u[0], e.u[1], e.u[2])
				frames[k] = Transform3D(_frame_basis(d, u), o)
		_skin_cache[sid] = [load(path), frames]
	var entry: Array = _skin_cache[sid]
	if entry[0] == null or (entry[1] as Dictionary).is_empty():
		return
	rest_frames = entry[1]
	skin_root = (entry[0] as PackedScene).instantiate()
	skin_root.top_level = true
	add_child(skin_root)
	skel = _find_skeleton(skin_root)
	if skel == null:
		skin_root.queue_free()
		return
	for m in skin_root.find_children("*", "MeshInstance3D", true, false):
		(m as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var depth := {}
	for i in skel.get_bone_count():
		var nm := skel.get_bone_name(i)
		if not rest_frames.has(nm):
			continue
		skin_name[i] = nm
		bone_rest[i] = skel.get_bone_global_rest(i)
		var dpt := 0
		var p := skel.get_bone_parent(i)
		while p >= 0:
			dpt += 1
			p = skel.get_bone_parent(p)
		depth[i] = dpt
	skin_order = skin_name.keys()
	skin_order.sort_custom(func(a, b): return depth[a] < depth[b])
	for i in skin_order:
		skin_parent[i] = skel.get_bone_parent(i)
	skinned = true


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for ch in n.get_children():
		var r := _find_skeleton(ch)
		if r != null:
			return r
	return null


static func _frame_basis(d: Vector3, u: Vector3) -> Basis:
	var z := d.normalized()
	var x := u.cross(z)
	if x.length_squared() < 1e-10:
		x = Vector3.RIGHT
	x = x.normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)


func _pose_skin(L: float, dt: float, f: Vector3, run_frac: float) -> void:
	var e := PackedVector3Array()
	var n := PackedVector3Array()
	var cl := PackedColorArray()
	var uv := PackedVector2Array()
	var ix := PackedInt32Array()
	_update_legs(dt, e, n, cl, uv, ix, L, run_frac)
	var roll_c := cos(roll)
	var roll_s := sin(roll)
	var origin := c.position
	skin_root.global_transform = Transform3D(Basis.from_scale(Vector3.ONE * L), origin)
	var inv_l := 1.0 / maxf(L, 0.0001)
	var cur := {}
	# spine
	for i in range(head_base_i, n_pts - 1):
		var d: Vector3 = vis[i] - vis[i + 1]
		cur["sp%d" % i] = _cur_frame(vis[i], d, pt_up[i], roll_c, roll_s, origin, inv_l)
	# head & jaw
	var hb := head_base_i
	var hpos: Vector3 = vis[hb]
	var hdir: Vector3 = vis[0] - hpos
	var hl := maxf(hdir.length(), 0.0005)
	hdir /= hl
	var href: Vector3 = pt_up[hb]
	var hup := (href - hdir * hdir.dot(href)).normalized()
	var hsd := hup.cross(hdir).normalized()
	hup = hup * roll_c + hsd * roll_s
	hsd = hup.cross(hdir).normalized()
	head_mi.global_transform = Transform3D(Basis(hsd * hl, hup * hl, hdir * hl), hpos - hup * prof_h[hb] * L * 0.2)
	cur["head"] = Transform3D(_frame_basis(hdir, hup), (hpos - origin) * inv_l)
	var want_jaw := 0.0
	if bite_t >= 0.0:
		var bk := bite_t / maxf(0.2, c.action_len)
		want_jaw = 0.75 * (1.0 - smoothstep(0.25, 0.38, bk)) * smoothstep(0.0, 0.12, bk)
	elif c.posture_amt > 0.05:
		want_jaw = 0.45 * c.posture_amt + sin(breath * 3.0) * 0.05
	elif c.action == "eat":
		want_jaw = 0.18 + 0.18 * sin(c.action_t * 9.0)
	elif c.action == "drink":
		want_jaw = 0.08 + 0.06 * sin(c.action_t * 6.0)
	elif dead:
		want_jaw = 0.25
	elif c.species_id == "croc" and c.brain != null and c.brain.get("state") == "bask":
		want_jaw = 0.5
	jaw_angle = lerpf(jaw_angle, want_jaw, 1.0 - exp(-(30.0 if want_jaw > jaw_angle else 22.0) * dt))
	var hinge := head_mi.global_transform.origin + hdir * 0.04 * hl
	var jd := hdir * cos(jaw_angle) - hup * sin(jaw_angle)
	var ju := hup * cos(jaw_angle) + hdir * sin(jaw_angle)
	cur["jaw"] = Transform3D(_frame_basis(jd, ju), (hinge - origin) * inv_l)
	# legs
	for k in 4:
		var up_k: Vector3 = leg_up[k]
		var hip: Vector3 = leg_hip[k]
		var knee: Vector3 = leg_knee[k]
		var wrist: Vector3 = leg_wrist[k]
		cur["leg%d_a" % k] = _cur_frame(hip, knee - hip, up_k, 1.0, 0.0, origin, inv_l)
		var d2 := wrist - knee
		var u2 := up_k
		if absf(d2.normalized().dot(up_k)) > 0.98:
			u2 = _vis_side(shoulder_i if k < 2 else pelvis_i)
		cur["leg%d_b" % k] = _cur_frame(knee, d2, u2, 1.0, 0.0, origin, inv_l)
		cur["leg%d_c" % k] = _cur_frame(wrist, leg_toe[k], up_k, 1.0, 0.0, origin, inv_l)
	# apply: desired global = D * rest, D = current frame * rest frame^-1
	var glob := {}
	for i in skin_order:
		var nm: String = skin_name[i]
		if not cur.has(nm):
			continue
		var D: Transform3D = cur[nm] * (rest_frames[nm] as Transform3D).affine_inverse()
		var G: Transform3D = D * (bone_rest[i] as Transform3D)
		glob[i] = G
		var p: int = skin_parent[i]
		var local := G
		if p >= 0:
			var pg: Transform3D = glob[p] if glob.has(p) else skel.get_bone_global_pose(p)
			local = pg.affine_inverse() * G
		skel.set_bone_pose(i, local)
	_update_tongue(dt, head_mi.global_transform * Vector3(0, 0.0, 0.97), hdir, L)


func _cur_frame(o: Vector3, d: Vector3, u: Vector3, rc: float, rs: float, origin: Vector3, inv_l: float) -> Transform3D:
	var z := d.normalized()
	var u0 := (u - z * z.dot(u))
	if u0.length_squared() < 1e-10:
		u0 = Vector3.UP
	u0 = u0.normalized()
	if rs != 0.0:
		var sd := u0.cross(z).normalized()
		u0 = u0 * rc + sd * rs
	return Transform3D(_frame_basis(z, u0), (o - origin) * inv_l)


# ------------------------------------------------------------------ mesh helpers

func _add_ellipsoid(verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, uvs: PackedVector2Array, idx: PackedInt32Array, center: Vector3, bx: Vector3, by: Vector3, bz: Vector3, col: Color, seg := 7, rings := 4) -> void:
	# bx/by/bz: scaled axes
	var base := verts.size()
	for i in rings + 1:
		var phi := PI * i / rings
		for j in seg:
			var th := TAU * j / seg
			var d := Vector3(sin(phi) * cos(th), cos(phi), sin(phi) * sin(th))
			verts.append(center + bx * d.x + by * d.y + bz * d.z)
			var n := bx * (d.x / maxf(bx.length_squared(), 1e-12)) + by * (d.y / maxf(by.length_squared(), 1e-12)) + bz * (d.z / maxf(bz.length_squared(), 1e-12))
			norms.append(n.normalized())
			cols.append(col)
			uvs.append(Vector2.ZERO)
	for i in rings:
		for j in seg:
			var a := base + i * seg + j
			var b := base + i * seg + (j + 1) % seg
			var a2 := a + seg
			var b2 := b + seg
			idx.append_array([a, a2, b2, a, b2, b])


func _add_tube(verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, uvs: PackedVector2Array, idx: PackedInt32Array, a: Vector3, b: Vector3, ra: float, rb: float, col: Color, seg := 6, col2 = null) -> void:
	var axis := b - a
	var len := axis.length()
	if len < 0.00001:
		return
	var dir := axis / len
	var ref := Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT
	var sx := dir.cross(ref).normalized()
	var sz := dir.cross(sx)
	var base := verts.size()
	var slope := (ra - rb) / len
	for ring in 2:
		var cen := a if ring == 0 else b
		var r := ra if ring == 0 else rb
		for j in seg:
			var th := TAU * j / seg
			var o := sx * cos(th) + sz * sin(th)
			verts.append(cen + o * r)
			norms.append((o + dir * slope).normalized())
			var cc: Color = col
			if col2 != null and (j + ring * 2) % 3 == 0:
				cc = col2
			cols.append(cc)
			uvs.append(Vector2.ZERO)
	for j in seg:
		var i0 := base + j
		var i1 := base + (j + 1) % seg
		var j0 := i0 + seg
		var j1 := i1 + seg
		idx.append_array([i0, j1, j0, i0, i1, j1])


# ------------------------------------------------------------------ legs

func _hip(k: int) -> Vector3:
	var gi := shoulder_i if k < 2 else pelvis_i
	var s := -1.0 if k % 2 == 0 else 1.0
	var p: Vector3 = vis[gi]
	var sd := _vis_side(gi)
	return p + sd * (prof_w[gi] * c.length * 0.62 * s) - pt_up[gi] * prof_h[gi] * c.length * 0.18


func _foot_rest(k: int, f: Vector3) -> Vector3:
	var L := c.length
	var gi := shoulder_i if k < 2 else pelvis_i
	var sd := _vis_side(gi)
	var s := -1.0 if k % 2 == 0 else 1.0
	var reach := (leg_upper + leg_lower) * L
	var sprawl := 0.82 if c.posture_amt < 0.5 else 0.6
	var fw := (0.22 if k < 2 else -0.08) * reach
	var p: Vector3 = vis[gi] + sd * (prof_w[gi] * L * 0.62 * s + reach * sprawl * s) + f * fw
	return _to_surface(p)


## Project a point onto the surface the animal stands on (ground or trunk bark).
func _to_surface(p: Vector3) -> Vector3:
	if climb_mode and not c.climb_tree.is_empty():
		var t: Dictionary = c.climb_tree
		var base_y: float = c.terrain.hmap(t.p.x, t.p.y)
		var y := p.y - base_y
		if y > 0.02:
			var rd := Vector2(p.x - t.p.x, p.z - t.p.y)
			if rd.length() < 0.0001:
				rd = Vector2(cos(c.climb_ang), sin(c.climb_ang))
			rd = rd.normalized() * Terrain.trunk_radius(t, y)
			return Vector3(t.p.x + rd.x, p.y, t.p.y + rd.y)
	p.y = c.terrain.height(p.x, p.z)
	return p


func _update_legs(dt: float, verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray, uvs: PackedVector2Array, idx: PackedInt32Array, L: float, run_frac: float) -> void:
	var f := c.fwd() if not climb_mode else Vector3.UP
	var reach := (leg_upper + leg_lower) * L
	var duty := lerpf(0.64, 0.46, run_frac)
	var cycle_dist := L * (0.36 + 0.16 * run_frac)
	var sweep := cycle_dist * duty
	var moving_now := c.speed > 0.04 * maxf(L, 0.2) and not c.swimming
	if climb_mode:
		moving_now = c.speed > 0.01
	var leg_col := base_col.lerp(spot_col, 0.08)
	var leg_spot := base_col.lerp(spot_col, 0.55)
	var claw_col := Color(0.66, 0.6, 0.5)
	for k in 4:
		var hip := _hip(k)
		var rest := _foot_rest(k, f)
		if dead or c.swimming or c.carried_by != null:
			var sd := _vis_side(shoulder_i if k < 2 else pelvis_i)
			var s := -1.0 if k % 2 == 0 else 1.0
			var tuck := hip + sd * (reach * 0.5 * s) - f * reach * 0.7 + Vector3.UP * reach * 0.05
			if dead:
				tuck = hip + sd * (reach * 0.7 * s) + Vector3.UP * reach * 0.4
			foot[k] = foot[k].lerp(tuck, 1.0 - exp(-10.0 * dt))
			swinging[k] = false
		elif moving_now:
			var ph := fposmod(cycle + LEG_PHASE[k], 1.0)
			var in_swing := ph < (1.0 - duty)
			var target := _to_surface(rest + f * (sweep * 0.5))
			if in_swing:
				if not swinging[k]:
					swinging[k] = true
					foot_from[k] = foot[k]
				var prog := ph / (1.0 - duty)
				var e := prog * prog * (3.0 - 2.0 * prog)
				var p: Vector3 = foot_from[k].lerp(target, e)
				p.y = lerpf(foot_from[k].y, target.y, e) + sin(prog * PI) * reach * (0.22 + 0.1 * run_frac)
				foot[k] = p
			else:
				if swinging[k]:
					swinging[k] = false
					foot[k] = target
					if lod_level == 0 and c.mass > 0.3 and (c.is_player or randf() < 0.3):
						Sfx.play_at("step", target, linear_to_db(clampf(c.size * 0.8, 0.05, 0.7)), clampf(1.4 - c.size * 0.5, 0.8, 1.5), 14.0)
				# planted: stays put in the world; guard against being dragged too far
				if foot[k].distance_to(rest) > reach * 1.25:
					foot[k] = foot[k].lerp(rest, 0.5)
		else:
			# idle: finish swings, then settle feet one at a time
			if swinging[k]:
				swing_t[k] += dt / 0.12
				var p2: Vector3 = foot_from[k].lerp(rest, clampf(swing_t[k], 0.0, 1.0))
				p2.y += sin(clampf(swing_t[k], 0.0, 1.0) * PI) * reach * 0.2
				foot[k] = p2
				if swing_t[k] >= 1.0:
					swinging[k] = false
					foot[k] = rest
			elif foot[k].distance_to(rest) > reach * 0.35:
				var any := false
				for q in 4:
					if swinging[q]:
						any = true
				if not any:
					swinging[k] = true
					swing_t[k] = 0.0
					foot_from[k] = foot[k]
		# ---- two-bone IK: elbow/knee pushed out to the side (sprawling limbs)
		var fp: Vector3 = foot[k]
		var gi_up: Vector3 = pt_up[shoulder_i if k < 2 else pelvis_i]
		var wrist := fp + gi_up * leg_r * L * 0.9
		var a := leg_upper * L
		var b := leg_lower * L
		var hf := wrist - hip
		var d := clampf(hf.length(), 0.001, (a + b) * 0.995)
		var dir := hf.normalized() if hf.length() > 0.0001 else Vector3.DOWN
		var sgn := -1.0 if k % 2 == 0 else 1.0
		var sd2 := _vis_side(shoulder_i if k < 2 else pelvis_i) * sgn
		var pole := (sd2 + gi_up * 0.7 + f * (-0.3 if k < 2 else 0.3)).normalized()
		var along := (a * a - b * b + d * d) / (2.0 * d)
		var hgt := sqrt(maxf(0.0, a * a - along * along))
		var pp := pole - dir * pole.dot(dir)
		pp = pp.normalized() if pp.length_squared() > 0.000001 else Vector3.UP
		var knee := hip + dir * along + pp * hgt
		wrist = hip + dir * d
		var lr := leg_r * L
		var hind := k >= 2
		leg_hip[k] = hip
		leg_knee[k] = knee
		leg_wrist[k] = wrist
		leg_up[k] = gi_up
		leg_toe[k] = (f * (1.0 if not hind else 0.45) + sd2 * (0.45 if not hind else 0.7)).normalized()
		if skinned:
			continue
		var r_up := lr * (1.75 if hind else 1.45)
		var seg_n := 8 if lod_level == 0 else 5
		# upper arm / thigh (muscular), forearm / shin
		_add_tube(verts, norms, cols, uvs, idx, hip, knee, r_up, lr * 1.05, leg_col, seg_n, leg_spot)
		_add_tube(verts, norms, cols, uvs, idx, knee, wrist, lr * 1.0, lr * 0.72, leg_col, seg_n, leg_spot)
		if lod_level == 0 and c.species_id != "skink":
			var kn_dir := (knee - hip).normalized()
			_add_ellipsoid(verts, norms, cols, uvs, idx, knee, sd2 * lr * 1.05, Vector3.UP * lr * 1.05, f * lr * 1.05, leg_col, 6, 3)
			_add_ellipsoid(verts, norms, cols, uvs, idx, hip, sd2 * r_up * 1.1, Vector3.UP * r_up * 0.9, f * r_up * 1.2, leg_col, 6, 3)
			# hand / foot: flat palm and five splayed clawed digits
			var toe_dir := (f * (1.0 if not hind else 0.45) + sd2 * (0.45 if not hind else 0.7)).normalized()
			var palm_c := wrist + toe_dir * lr * 0.9 - gi_up * lr * 0.45
			_add_ellipsoid(verts, norms, cols, uvs, idx, palm_c, toe_dir.cross(gi_up).normalized() * lr * 1.2, gi_up * lr * 0.45, toe_dir * lr * 1.3, leg_col, 6, 3)
			_add_tube(verts, norms, cols, uvs, idx, wrist, palm_c, lr * 0.72, lr * 0.8, leg_col, 6)
			var toe_lens := [0.55, 0.8, 1.0, 1.05, 0.7] if not hind else [0.5, 0.75, 1.0, 1.25, 0.65]
			for tI in toes:
				var ang := (tI - 2) * 0.34 * sgn
				var td := toe_dir.rotated(gi_up, ang)
				var base_p := palm_c + td * lr * 0.9
				var tl: float = lr * 2.6 * toe_lens[tI]
				var tip := base_p + td * tl
				if not climb_mode:
					tip.y = maxf(tip.y - lr * 0.2, c.terrain.height(tip.x, tip.z) + lr * 0.12)
				_add_tube(verts, norms, cols, uvs, idx, base_p, tip, lr * 0.34, lr * 0.24, leg_col, 4)
				var claw_tip := tip + td * lr * 0.85 - gi_up * lr * 0.35
				_add_tube(verts, norms, cols, uvs, idx, tip, claw_tip, lr * 0.2, lr * 0.03, claw_col, 4)
		if debug_legs:
			print("leg ", k, " hip ", hip - c.position, " knee ", knee - c.position, " foot ", fp - c.position)


func _update_tongue(dt: float, tip: Vector3, dir: Vector3, L: float) -> void:
	if c.species_id == "croc" or dead:
		tongue.visible = false
		return
	tongue_timer -= dt
	if c.brain != null and c.brain.get("tongue_now") == true:
		c.brain.tongue_now = false
		tongue_timer = 0.0
	if tongue_timer <= 0.0 and tongue_t <= 0.0 and c.action == "":
		tongue_t = 0.32
		tongue_timer = randf_range(1.5, 4.5) if c.speed < 0.1 else randf_range(0.8, 2.0)
		if c.is_player or (lod_level == 0 and randf() < 0.3):
			Sfx.play_at("tongue", tip, linear_to_db(clampf(c.size * 0.6, 0.05, 0.5)), 1.2, 8.0)
	if tongue_t > 0.0:
		tongue_t -= dt
		var k := 1.0 - tongue_t / 0.32
		var ext := sin(k * PI)
		var flick := sin(k * PI * 6.0) * 0.25
		tongue.visible = ext > 0.15
		if not tongue.visible:
			return
		var tl := L * 0.09 * ext
		var d := dir.rotated(Vector3.UP, flick * 0.4)
		d.y += flick * 0.3 - 0.1
		d = d.normalized()
		var sx := Vector3.UP.cross(d).normalized()
		var basis := Basis(sx * L * 0.03, d.cross(sx).normalized() * L * 0.03, d * tl)
		tongue.global_transform = Transform3D(basis, tip - d * L * 0.01)
	else:
		tongue.visible = false
