class_name CameraRig
extends Node3D
## Third-person camera that hugs the ground at animal scale; also provides the
## slow cinematic orbit used behind the menus and on death.

var cam := Camera3D.new()
var world: World
var mode := "orbit"          # orbit, follow, death
var target: Creature = null
var yaw := 0.0
var pitch := -0.18
var zoom := 1.0
var pivot := Vector3.ZERO
var shake := 0.0
var orbit_center := Vector3(-26, 3, 50)
var orbit_t := 0.0
var sens := 0.0025


func setup(w: World) -> void:
	world = w
	cam.fov = Game.settings.fov
	cam.near = 0.02
	cam.far = 900.0
	add_child(cam)
	cam.current = true
	Game.settings_changed.connect(func(): cam.fov = Game.settings.fov)


func follow(c: Creature) -> void:
	target = c
	mode = "follow"
	yaw = c.yaw + PI
	pitch = -0.2
	pivot = _pivot_of(c)


func orbit(center: Vector3) -> void:
	orbit_center = center
	mode = "orbit"


func death_view(c: Creature) -> void:
	target = c
	mode = "death"
	orbit_t = 0.0


func add_shake(a: float) -> void:
	shake = minf(1.0, shake + a)


func _unhandled_input(event: InputEvent) -> void:
	if mode != "follow" or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		var s: float = sens * Game.settings.mouse_sensitivity
		yaw -= event.relative.x * s
		var inv := -1.0 if Game.settings.invert_y else 1.0
		pitch = clampf(pitch - event.relative.y * s * inv, -1.25, 0.55)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom = clampf(zoom - 0.1, 0.55, 1.8)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom = clampf(zoom + 0.1, 0.55, 1.8)


func _pivot_of(c: Creature) -> Vector3:
	return c.position + Vector3.UP * (c.length * 0.16 + 0.04) + c.fwd() * c.length * 0.1


## Forward direction on the ground plane the camera is looking along.
func flat_forward() -> Vector3:
	return Vector3(-sin(yaw), 0, -cos(yaw))


func _process(delta: float) -> void:
	var dt := minf(delta, 0.1)
	var t := world.terrain
	match mode:
		"manual":
			return
		"orbit":
			# slow drift over the water, looking out at the shore
			orbit_t += dt * 0.02
			var r := 7.0
			var p := orbit_center + Vector3(cos(orbit_t) * r, 0.0, sin(orbit_t) * r)
			p.y = maxf(1.4 + sin(orbit_t * 1.7) * 0.3, t.height(p.x, p.z) + 1.2)
			global_position = p
			var look_dir := Vector3(cos(orbit_t + 0.9), -0.06, sin(orbit_t + 0.9))
			cam.global_transform = Transform3D(Basis.looking_at(look_dir, Vector3.UP), p)
			cam.near = 0.1
			return
		"death":
			if target == null or not is_instance_valid(target):
				mode = "orbit"
				return
			orbit_t += dt
			var c := target.position + Vector3.UP * target.length * 0.1
			var r2 := target.length * 2.5 + 1.0 + orbit_t * 0.25
			var a := yaw + orbit_t * 0.12
			var p2 := c + Vector3(sin(a) * r2, r2 * 0.5 + orbit_t * 0.15, cos(a) * r2)
			p2.y = maxf(p2.y, t.height(p2.x, p2.z) + 0.3)
			global_position = p2
			cam.global_transform = Transform3D(Basis.looking_at(c - p2, Vector3.UP), p2)
			return
	if target == null or not is_instance_valid(target):
		return
	var L := target.length
	var want_pivot := _pivot_of(target)
	if target.swimming:
		want_pivot.y = maxf(want_pivot.y, 0.05 + L * 0.1)
	pivot = pivot.lerp(want_pivot, 1.0 - exp(-12.0 * dt))
	var dist := clampf(L * 2.1 + 0.55, 0.75, 6.0) * zoom
	var dir := Vector3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
	var want := pivot + dir * dist
	# terrain occlusion: march from pivot to camera
	var steps := 10
	var best := dist
	for i in range(1, steps + 1):
		var f := float(i) / steps
		var q := pivot + dir * dist * f
		var gy := t.height(q.x, q.z) + 0.06 + L * 0.04
		if q.y < gy:
			best = dist * (f - 1.0 / steps)
			break
	best = maxf(best, L * 0.6)
	var cp := pivot + dir * best
	cp.y = maxf(cp.y, t.height(cp.x, cp.z) + 0.05 + L * 0.04)
	if cp.y < 0.05 and t.water_depth(cp.x, cp.z) > 0.0:
		cp.y = 0.08
	if shake > 0.0:
		shake = maxf(0.0, shake - dt * 2.5)
		cp += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * shake * 0.05 * (0.3 + L)
	global_position = cp
	var look := pivot + Vector3.UP * L * 0.05
	if (look - cp).length() > 0.001:
		cam.global_transform = Transform3D(Basis.looking_at(look - cp, Vector3.UP), cp)
	cam.near = clampf(L * 0.02, 0.01, 0.08)
