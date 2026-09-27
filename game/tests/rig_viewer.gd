extends Node3D
## Rig viewer: minimal fake world with one line of animals per species, each
## animal in a different state (walk, run, fly, idle, eat, rest, bite, dead),
## animated on a treadmill (positions reset each frame, gait keeps advancing).
## Saves screenshots to tools/shots/rig_*.png and quits.
##
## Optional user args (after "--"):
##   --species=dingo,crow   only these groups
##   --states=walk,run      close-ups only for these states (default walk,run,fly)
##   --frames=3             close-up frames per state (default 2)
##   --nogroup              skip group overview shots

class FakeBrain:
	extends RefCounted
	var look_point = null

	func update(_dt: float) -> void:
		pass


const OUT := "E:/dev/varaneMode/tools/shots/rigs/"
const SPECIES := ["dingo", "wallaby", "mouse", "turkey", "crow", "eagle", "frog", "grasshopper"]
const STATES := ["walk", "run", "fly", "climb", "takeoff", "idle", "look", "eat", "rest", "bite", "dead"]
const BIRD_ONLY := ["fly", "climb", "takeoff"]
const FIXED_DT := 1.0 / 60.0

var terrain: Terrain
var time := 0.0
var player_life = null

var cam: Camera3D
var entries: Array = []        # {c, home, state, sp}
var groups := {}               # sid -> {center, width, L, entries}
var sel_species: Array = []
var sel_states: Array = ["walk", "run", "fly"]
var frames := 3
var do_group := true
var shot_list: Array = []


func query(_pos: Vector3, _r: float) -> Array:
	return []


func remove_creature(c) -> void:
	if is_instance_valid(c):
		c.visible = false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--species="):
			sel_species = Array(a.substr(10).split(","))
		elif a.begins_with("--states="):
			sel_states = Array(a.substr(9).split(","))
		elif a.begins_with("--frames="):
			frames = int(a.substr(9))
		elif a == "--nogroup":
			do_group = false
	DirAccess.make_dir_recursive_absolute(OUT)
	terrain = Terrain.new()
	terrain.generate(7)
	_setup_env()
	var land := _find_flat(34.0, 44.0)
	print("[rig_viewer] flat area at ", land, " h=", terrain.height(land.x, land.y))
	_ground_mesh(land, 44.0, 56.0, 0.5)
	# lay out groups along Z, animals of each group along X
	var z := land.y - 20.0
	for sid in SPECIES:
		if not sel_species.is_empty() and not (sid in sel_species):
			continue
		var d: Dictionary = Species.DEFS[sid]
		var L: float = d.length
		var spacing := maxf(L * 2.6, 0.3)
		if sid == "eagle":
			spacing = 3.2
		elif d.rig == "bird":
			spacing = maxf(L * 3.2, 0.5)
		var states: Array = []
		for s in STATES:
			if s in BIRD_ONLY and d.rig != "bird":
				continue
			states.append(s)
		var width := spacing * (states.size() - 1)
		var x0 := land.x - width * 0.5
		var ge: Array = []
		for i in states.size():
			var p := Vector3(x0 + i * spacing, 0, z)
			p.y = terrain.height(p.x, p.z)
			var e := _spawn(sid, states[i], p)
			ge.append(e)
		groups[sid] = {"center": Vector3(land.x, terrain.height(land.x, z), z), "width": width, "L": L, "entries": ge, "rig": d.rig}
		z += maxf(4.0, L * 6.0) if sid != "eagle" else 8.0
	# fish over deep water
	if sel_species.is_empty() or "fish" in sel_species:
		var wp := _find_water()
		print("[rig_viewer] water at ", wp, " depth=", terrain.water_depth(wp.x, wp.y))
		_ground_mesh(wp, 8.0, 8.0, 0.25)
		_water(wp, 10.0)
		var ge: Array = []
		var fstates := ["walk", "run", "idle", "dead"]
		for i in fstates.size():
			var p := Vector3(wp.x - 0.9 + i * 0.6, -0.3, wp.y)
			ge.append(_spawn("fish", fstates[i], p))
		groups["fish"] = {"center": Vector3(wp.x, -0.3, wp.y), "width": 1.8, "L": 0.3, "entries": ge, "rig": "fish"}
	cam = Camera3D.new()
	cam.fov = 38.0
	cam.near = 0.01
	cam.far = 400.0
	add_child(cam)
	_print_tris()
	_run.call_deferred()


func _spawn(sid: String, state: String, p: Vector3) -> Dictionary:
	var c := Creature.new()
	c.setup(self, sid, Species.DEFS[sid].ref_mass, p, PI * 0.5)
	add_child(c)
	var e := {"c": c, "home": p, "state": state, "sid": sid}
	match state:
		"rest":
			c.resting = true
		"fly", "climb":
			c.flying = true
			c.fly_alt = 3.0
		"eat":
			c.start_eat(null)
		"look":
			var b := FakeBrain.new()
			c.brain = b
	entries.append(e)
	return e


func _setup_env() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, 35, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	add_child(sun)
	var env := Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.35, 0.55, 0.85)
	sm.sky_horizon_color = Color(0.75, 0.78, 0.8)
	sm.ground_bottom_color = Color(0.3, 0.26, 0.2)
	sm.ground_horizon_color = Color(0.7, 0.66, 0.6)
	sky.sky_material = sm
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)


func _find_flat(w: float, d: float) -> Vector2:
	var best := Vector2.ZERO
	var best_s := 1e9
	for gx in range(-120, 121, 6):
		for gz in range(-120, 121, 6):
			var mn := 1e9
			var mx := -1e9
			for i in 7:
				for j in 7:
					var hh := terrain.height(gx - w * 0.5 + w * i / 6.0, gz - d * 0.5 + d * j / 6.0)
					mn = minf(mn, hh)
					mx = maxf(mx, hh)
			if mn < 0.5:
				continue
			if mx - mn < best_s:
				best_s = mx - mn
				best = Vector2(gx, gz)
	return best


func _find_water() -> Vector2:
	var best := Vector2(0, 0)
	var best_d := -1.0
	for gx in range(-140, 141, 4):
		for gz in range(-140, 141, 4):
			var dd := terrain.water_depth(gx, gz)
			if dd > 1.0:
				# prefer a spot that's deep in a neighbourhood too
				var m := minf(minf(terrain.water_depth(gx + 1.5, gz), terrain.water_depth(gx - 1.5, gz)), minf(terrain.water_depth(gx, gz + 1.5), terrain.water_depth(gx, gz - 1.5)))
				if m > best_d:
					best_d = m
					best = Vector2(gx, gz)
	return best


func _ground_mesh(center: Vector2, w: float, d: float, cell: float) -> void:
	var mb := MeshBuilder.new()
	var nx := int(w / cell)
	var nz := int(d / cell)
	var x0 := center.x - w * 0.5
	var z0 := center.y - d * 0.5
	for j in nz:
		for i in nx:
			var xa := x0 + i * cell
			var za := z0 + j * cell
			var p00 := Vector3(xa, terrain.height(xa, za), za)
			var p10 := Vector3(xa + cell, terrain.height(xa + cell, za), za)
			var p01 := Vector3(xa, terrain.height(xa, za + cell), za + cell)
			var p11 := Vector3(xa + cell, terrain.height(xa + cell, za + cell), za + cell)
			var col := _ground_col(xa, za, p00.y)
			mb.tri(p00, p01, p11, col, col, col)
			mb.tri(p00, p11, p10, col, col, col)
	var mi := MeshInstance3D.new()
	mi.mesh = mb.commit()
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.roughness = 0.95
	mi.material_override = m
	add_child(mi)


func _ground_col(x: float, z: float, h: float) -> Color:
	var n := fposmod(sin(x * 12.9898 + z * 78.233) * 43758.5453, 1.0)
	var base := Color(0.62, 0.55, 0.38).lerp(Color(0.5, 0.52, 0.32), fposmod(sin(x * 0.7) * sin(z * 0.9) * 3.0, 1.0) * 0.4)
	if h < 0.05:
		base = Color(0.45, 0.4, 0.3)
	return base * (0.92 + 0.12 * n)


func _water(center: Vector2, size: float) -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(size, size)
	mi.mesh = pm
	mi.position = Vector3(center.x, 0.0, center.y)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.25, 0.38, 0.36, 0.35)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.1
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _print_tris() -> void:
	var done := {}
	for e in entries:
		var sid: String = e.sid
		if done.has(sid):
			continue
		done[sid] = true
		var c: Creature = e.c
		var tris := 0
		var parts := 0
		var stack: Array = [c.rig]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if n is MeshInstance3D and n.mesh != null:
				tris += n.mesh.get_faces().size() / 3
				parts += 1
			for ch in n.get_children():
				stack.append(ch)
		print("[rig_viewer] %s: %d tris, %d parts" % [sid, tris, parts])


# ---------------------------------------------------------------- simulation

func _process(_delta: float) -> void:
	var dt := FIXED_DT
	time += dt
	for e in entries:
		var c: Creature = e.c
		var st: String = e.state
		var fwd := Vector3(1, 0, 0)
		match st:
			"walk":
				c.steer(fwd, c.walk_speed())
			"run":
				c.steer(fwd, c.run_speed())
			"fly":
				c.steer(fwd, c.sp.get("fly_speed", c.run_speed()))
			"takeoff":
				# alternate between flying and walking to exercise fold/unfold
				var fl := fmod(time, 3.0) > 1.5
				if fl != c.flying:
					c.flying = fl
					c.fly_alt = 1.2
				c.steer(fwd, c.walk_speed() if not fl else 4.0)
			"climb":
				c.steer(fwd, c.sp.get("fly_speed", c.run_speed()) * 0.7)
				c.fly_alt = 2.5 + 2.0 * sin(time * 0.8)
			"bite":
				if c.alive and c.action == "" and fmod(time, 1.3) < dt * 1.5:
					c.try_bite()
			"look":
				if c.brain != null and cam != null:
					c.brain.look_point = cam.global_position
			"dead":
				if c.alive and time > 0.4:
					c.die("test")
		c.tick(dt)
		# treadmill: keep the animal at its spot (gait phase still advances)
		var home: Vector3 = e.home
		if st != "fly" and st != "climb":
			c.position.x = home.x
			c.position.z = home.z
			if c.sp.get("fish", false):
				pass
			elif not c.flying:
				c.position.y = terrain.height(home.x, home.z)
		else:
			c.position.x = home.x
			c.position.z = home.z
		c.yaw = PI * 0.5
		c.rotation.y = c.yaw
		c.update_visual(dt)


# ---------------------------------------------------------------- shots

func _look(from: Vector3, to: Vector3) -> void:
	cam.global_position = from
	cam.look_at(to, Vector3.UP)


func _shoot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(OUT + name + ".png")
	print("[rig_viewer] saved ", name)


func _wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _capture() -> Image:
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


func _closeup(e: Dictionary, L: float, view := 0) -> void:
	var c: Creature = e.c
	var st: String = e.state
	var tgt := c.global_position + Vector3(0, L * 0.3, 0)
	var k := 1.0
	if st == "fly" or st == "climb" or st == "takeoff":
		k = 1.9 if e.sid == "eagle" else 1.6
	var from := tgt + Vector3(L * 0.8, L * 0.45, -L * 2.1) * k
	if view == 1:
		from = tgt + Vector3(-L * 0.3, L * 0.25, -L * 2.3) * k      # pure side
		if st == "fly" or st == "climb":
			from = tgt + Vector3(-L * 1.6, L * 1.7, -L * 1.5) * k   # behind, above
	elif view == 2:
		from = tgt + Vector3(L * 1.6, L * 1.3, L * 0.9) * k         # front-high other side
	if e.sid == "fish":
		from = tgt + Vector3(0.25, 0.35, -0.45) if view != 1 else tgt + Vector3(0.0, 0.05, -0.6)
	_look(from, tgt)


func _sheet(imgs: Array, cols: int, name: String) -> void:
	if imgs.is_empty():
		return
	var tw := 640
	var th := 360
	var rows := int(ceil(imgs.size() / float(cols)))
	var first: Image = imgs[0]
	var sheet := Image.create(tw * cols, th * rows, false, first.get_format())
	sheet.fill(Color(0.1, 0.1, 0.1))
	for i in imgs.size():
		var im: Image = imgs[i]
		im.resize(tw, th, Image.INTERPOLATE_BILINEAR)
		sheet.blit_rect(im, Rect2i(0, 0, tw, th), Vector2i((i % cols) * tw, (i / cols) * th))
	sheet.save_png(OUT + name + ".png")
	print("[rig_viewer] saved ", name)


func _run() -> void:
	await _wait_frames(int(2.0 / FIXED_DT))
	for sid in groups:
		var g: Dictionary = groups[sid]
		var L: float = g.L
		# all states, 3/4 view
		var imgs: Array = []
		for e in g.entries:
			_closeup(e, L, 0)
			imgs.append(await _capture())
		_sheet(imgs, 3, "rig_%s_states" % sid)
		# gait strip: moving states, side view, several phases
		imgs = []
		for e in g.entries:
			var st: String = e.state
			if not (st in sel_states):
				continue
			for fi in frames:
				_closeup(e, L, 1)
				imgs.append(await _capture())
				await _wait_frames(5)
		_sheet(imgs, 3, "rig_%s_gait" % sid)
		if do_group:
			imgs = []
			for e in g.entries:
				_closeup(e, L, 2)
				imgs.append(await _capture())
			_sheet(imgs, 3, "rig_%s_front" % sid)
	print("[rig_viewer] done")
	get_tree().quit()
