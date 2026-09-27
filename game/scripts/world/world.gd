class_name World
extends Node3D
## The living world: terrain, sky/day cycle, ecosystem population and the
## update loop for every creature (with distance-based LOD).

signal player_died(cause: String)
signal hour_changed(hour: float)

const DAY_SEC_PER_HOUR := 24.0      # real seconds per game hour during daylight
const NIGHT_SEC_PER_HOUR := 11.0
const GRID := 12.0

var terrain := Terrain.new()
var creatures: Array = []
var carcasses: Array = []
var nests: Array = []           # monitor clutches {p:Vector3, eggs:int, t:float, lineage:int}
var grid := {}
var time := 0.0                 # simulated seconds
var hour := 7.0
var day := 1
var player: Creature = null
var player_life: PlayerLife = null
var camera: CameraRig = null
var env: Environment
var sun: DirectionalLight3D
var sky_mat: ShaderMaterial
var frame := 0
var quality := 2
var spawn_t := 5.0
var ambience_t := 0.0
var fx_root: Node3D
var egg_nodes: Array = []
var menu_mode := true
var sleep_mode := false
var stats_kills := 0
var perf_acc := [0, 0, 0]
var natural_t := 40.0
var perf_sp := {}
var pollen: GPUParticles3D
var fireflies: GPUParticles3D
var net_client := false         # connected to another player's world: animals come from the host
var puppets := {}               # host creature id -> puppet Creature (client only)
var _snap_serial := 0
var _nest_sig := ""

# population targets per species
const POP := {
	"grasshopper": 60, "mouse": 16, "skink": 16, "frog": 14, "fish": 28,
	"turkey": 5, "wallaby": 8, "crow": 5, "dingo": 3, "eagle": 1, "croc": 2,
}


func build(q: int) -> void:
	quality = q
	Game.world = self
	var t0 := Time.get_ticks_msec()
	terrain.generate(1337)
	print("terrain gen ms: ", Time.get_ticks_msec() - t0)
	var vis := Node3D.new()
	vis.name = "Static"
	add_child(vis)
	WorldVisuals.build(vis, terrain, quality)
	print("visuals ms: ", Time.get_ticks_msec() - t0)
	fx_root = Node3D.new()
	add_child(fx_root)
	_build_environment()
	camera = CameraRig.new()
	add_child(camera)
	camera.setup(self)
	_build_particles()
	_populate()
	_update_sky(0.0)
	print("world ready ms: ", Time.get_ticks_msec() - t0)


# ------------------------------------------------------------------ environment

func _build_environment() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://assets/shaders/sky.gdshader")
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.fog_enabled = true
	env.fog_density = 0.006
	env.fog_sky_affect = 0.25
	env.fog_aerial_perspective = 0.2
	env.glow_enabled = true
	env.glow_intensity = 0.25
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 2.5
	env.ssao_enabled = quality >= 2
	env.ssao_radius = 1.0
	env.ssao_intensity = 1.4
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.08
	env.adjustment_contrast = 1.04
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 90.0 if quality >= 1 else 50.0
	sun.directional_shadow_split_1 = 0.05
	sun.directional_shadow_split_2 = 0.16
	sun.directional_shadow_split_3 = 0.45
	sun.shadow_blur = 1.5
	sun.light_angular_distance = 0.8
	add_child(sun)


func apply_quality(q: int) -> void:
	quality = q
	env.ssao_enabled = q >= 2
	sun.directional_shadow_max_distance = [40.0, 55.0, 70.0][clampi(q, 0, 2)]
	get_viewport().msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_2X][clampi(q, 0, 2)]
	get_viewport().use_taa = false
	get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if q == 0 else Viewport.SCREEN_SPACE_AA_DISABLED


static func _keys(k: Array, h: float):
	# k: [[hour, value], ...] sorted, wraps at 24
	for i in range(k.size() - 1):
		if h >= k[i][0] and h <= k[i + 1][0]:
			var f: float = (h - k[i][0]) / maxf(0.0001, k[i + 1][0] - k[i][0])
			return lerp(k[i][1], k[i + 1][1], f)
	return k[0][1]


const K_TOP := [[0.0, Color(0.01, 0.015, 0.04)], [4.8, Color(0.02, 0.03, 0.07)], [6.0, Color(0.2, 0.25, 0.45)], [7.5, Color(0.28, 0.46, 0.75)], [12.0, Color(0.24, 0.47, 0.82)], [17.0, Color(0.3, 0.45, 0.72)], [18.6, Color(0.28, 0.25, 0.45)], [19.6, Color(0.05, 0.05, 0.12)], [24.0, Color(0.01, 0.015, 0.04)]]
const K_HOR := [[0.0, Color(0.03, 0.04, 0.07)], [4.8, Color(0.05, 0.05, 0.09)], [6.0, Color(0.95, 0.58, 0.38)], [7.5, Color(0.9, 0.78, 0.62)], [12.0, Color(0.82, 0.82, 0.76)], [17.0, Color(0.9, 0.78, 0.6)], [18.6, Color(0.98, 0.5, 0.3)], [19.6, Color(0.1, 0.08, 0.14)], [24.0, Color(0.03, 0.04, 0.07)]]
const K_SUN := [[0.0, Color(0.5, 0.6, 1.0)], [5.8, Color(0.5, 0.6, 1.0)], [6.2, Color(1.0, 0.55, 0.3)], [8.0, Color(1.0, 0.88, 0.72)], [12.0, Color(1.0, 0.96, 0.88)], [16.5, Color(1.0, 0.85, 0.65)], [18.5, Color(1.0, 0.5, 0.28)], [18.9, Color(0.5, 0.6, 1.0)], [24.0, Color(0.5, 0.6, 1.0)]]
const K_AMB := [[0.0, Color(0.1, 0.12, 0.2)], [5.0, Color(0.12, 0.13, 0.22)], [6.5, Color(0.5, 0.42, 0.4)], [9.0, Color(0.62, 0.6, 0.56)], [15.0, Color(0.64, 0.6, 0.55)], [18.3, Color(0.55, 0.4, 0.38)], [19.5, Color(0.13, 0.13, 0.22)], [24.0, Color(0.1, 0.12, 0.2)]]


func sun_elevation() -> float:
	if hour < 6.0 or hour > 18.8:
		return 0.0
	return clampf(sin((hour - 6.0) / 12.8 * PI), 0.0, 1.0)


func is_night() -> bool:
	return hour < 5.7 or hour > 19.3


func _update_sky(_dt: float) -> void:
	var day_t := (hour - 6.0) / 12.8
	var a := day_t * PI
	var sun_dir := Vector3(cos(a), sin(a), -0.35 * sin(a) - 0.12).normalized()
	var night_t := fmod(hour - 18.8 + 24.0, 24.0) / 11.2
	var ma := night_t * PI
	var moon_dir := Vector3(cos(ma) * 0.8, 0.25 + 0.55 * sin(ma), 0.4).normalized()
	var elev := sun_elevation()
	var sun_col: Color = _keys(K_SUN, hour)
	var light_dir: Vector3
	var energy: float
	if hour >= 6.0 and hour <= 18.8:
		light_dir = sun_dir
		energy = 1.35 * smoothstep(0.0, 0.18, elev)
	else:
		light_dir = moon_dir
		var fade := minf(smoothstep(18.8, 19.6, hour) if hour > 12.0 else 1.0, 1.0 - smoothstep(5.2, 6.0, hour) if hour < 12.0 else 1.0)
		energy = 0.18 * fade
	if light_dir.y < 0.08:
		light_dir.y = 0.08
		light_dir = light_dir.normalized()
	sun.transform.basis = Basis.looking_at(-light_dir, Vector3.UP)
	sun.light_color = sun_col
	sun.light_energy = energy
	sun.shadow_opacity = clampf(energy * 1.2, 0.4, 1.0)
	var top: Color = _keys(K_TOP, hour)
	var hor: Color = _keys(K_HOR, hour)
	sky_mat.set_shader_parameter("top_col", top)
	sky_mat.set_shader_parameter("horizon_col", hor)
	sky_mat.set_shader_parameter("ground_col", hor.darkened(0.55))
	sky_mat.set_shader_parameter("sun_col", sun_col if hour > 5.5 and hour < 19.3 else Color(0.6, 0.65, 0.8))
	sky_mat.set_shader_parameter("sun_dir", sun_dir if hour > 5.5 and hour < 19.3 else moon_dir)
	var stars := 1.0 - smoothstep(4.8, 6.0, hour) if hour < 12.0 else smoothstep(18.8, 20.0, hour)
	sky_mat.set_shader_parameter("star_amount", stars)
	env.ambient_light_color = _keys(K_AMB, hour)
	env.ambient_light_energy = 1.0
	env.fog_light_color = hor.lerp(top, 0.3)
	env.fog_density = 0.0026 + (0.004 if is_night() else 0.0) + (0.006 * (1.0 - smoothstep(5.5, 8.0, hour)) if hour < 9.0 else 0.0)
	env.tonemap_exposure = 1.0 if not is_night() else 1.35


func air_temp() -> float:
	# degrees C: cool nights, hot early afternoon
	var h := hour
	var warm := clampf(sin((h - 7.0) / 14.0 * PI), 0.0, 1.0) if h > 7.0 and h < 21.0 else 0.0
	return 16.0 + 16.0 * warm


# ------------------------------------------------------------------ particles

func _build_particles() -> void:
	pollen = GPUParticles3D.new()
	pollen.amount = 160 if quality >= 1 else 60
	pollen.lifetime = 6.0
	pollen.visibility_aabb = AABB(Vector3(-20, -5, -20), Vector3(40, 15, 40))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(14, 3, 14)
	pm.gravity = Vector3(0.15, 0.02, 0.05)
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 0.15
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.4
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	pollen.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.025, 0.025)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.95, 0.8, 0.4)
	mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	mat.distance_fade_min_distance = 0.6
	mat.distance_fade_max_distance = 3.0
	qm.material = mat
	pollen.draw_pass_1 = qm
	add_child(pollen)
	fireflies = GPUParticles3D.new()
	fireflies.amount = 50
	fireflies.lifetime = 5.0
	fireflies.visibility_aabb = AABB(Vector3(-30, -5, -30), Vector3(60, 15, 60))
	var fm := ParticleProcessMaterial.new()
	fm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	fm.emission_box_extents = Vector3(22, 1.5, 22)
	fm.gravity = Vector3.ZERO
	fm.turbulence_enabled = true
	fm.turbulence_noise_strength = 1.0
	fm.initial_velocity_max = 0.2
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0))
	curve.add_point(Vector2(0.2, 1))
	curve.add_point(Vector2(0.5, 0.2))
	curve.add_point(Vector2(0.7, 1))
	curve.add_point(Vector2(1, 0))
	var ct := CurveTexture.new()
	ct.curve = curve
	fm.scale_curve = ct
	fireflies.process_material = fm
	var fq := QuadMesh.new()
	fq.size = Vector2(0.06, 0.06)
	var fmat := StandardMaterial3D.new()
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	fmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	fmat.albedo_color = Color(0.8, 1.0, 0.4)
	fmat.emission_enabled = true
	fmat.emission = Color(0.7, 1.0, 0.3)
	fmat.emission_energy_multiplier = 3.0
	fq.material = fmat
	fireflies.draw_pass_1 = fq
	fireflies.emitting = false
	add_child(fireflies)


# ------------------------------------------------------------------ population

func spawn(species: String, mass: float, p2: Vector2, yaw := -999.0) -> Creature:
	var c := Creature.new()
	var y := terrain.height(p2.x, p2.y)
	c.setup(self, species, mass, Vector3(p2.x, y, p2.y), yaw)
	c.brain = Brain.new(c)
	add_child(c)
	creatures.append(c)
	return c


func _species_spawn_point(sp_id: String, far_from: Vector3, min_d: float) -> Vector2:
	for attempt in 30:
		var p := Vector2(INF, INF)
		match sp_id:
			"grasshopper", "mouse":
				p = terrain.random_land_point(Vector2.ZERO, Terrain.PLAY_HALF, 0.4)
				if terrain.grassiness(p.x, p.y) < 0.3:
					continue
			"skink":
				var pick := randi() % 3
				if pick == 0:
					p = terrain.random_land_point(Terrain.OUTCROP_POS, 35.0, 0.4)
				elif pick == 1 and not terrain.logs.is_empty():
					var l: Dictionary = terrain.logs[randi() % terrain.logs.size()]
					p = terrain.random_land_point((l.a + l.b) * 0.5, 4.0, 0.3)
				else:
					var s: Dictionary = terrain.slabs[randi() % terrain.slabs.size()]
					p = terrain.random_land_point(s.p, 5.0, 0.3)
			"frog":
				var shore := terrain.nearest_shore(terrain.random_land_point(Vector2(Terrain.POND_POS.x, Terrain.POND_POS.y), 60.0, -1.0), 40.0)
				if shore.y < -900.0:
					continue
				p = Vector2(shore.x, shore.z)
			"fish":
				if randf() < 0.3:
					p = terrain.random_water_point(Terrain.POND_POS, Terrain.POND_R, 0.6)
				else:
					var rp := terrain.river_pts[randi() % terrain.river_pts.size()]
					p = terrain.random_water_point(rp, 6.0, 0.8)
			"wallaby":
				p = terrain.random_land_point(Vector2(60, 110) if randf() < 0.5 else Vector2(-40, -80), 30.0, 0.5)
			"dingo":
				p = terrain.random_land_point(Terrain.DEN_POS, 12.0, 0.5)
			"crow":
				p = terrain.random_land_point(Vector2.ZERO, 120.0, 0.5)
			"eagle":
				p = terrain.random_land_point(Vector2.ZERO, 100.0, 0.0)
			"croc":
				var rp2 := terrain.river_pts[randi_range(8, terrain.river_pts.size() - 20)]
				p = terrain.random_water_point(rp2, 8.0, 1.2)
			"turkey":
				var m: Dictionary = terrain.turkey_mounds[randi() % terrain.turkey_mounds.size()]
				p = terrain.random_land_point(m.p, 8.0, 0.4)
		if p.x == INF:
			continue
		if absf(p.x) > Terrain.PLAY_HALF or absf(p.y) > Terrain.PLAY_HALF:
			continue
		if far_from != Vector3.INF and Vector2(far_from.x, far_from.z).distance_to(p) < min_d:
			continue
		return p
	return Vector2(INF, INF)


func _spawn_species(sp_id: String, far_from := Vector3.INF, min_d := 0.0) -> Creature:
	var p := _species_spawn_point(sp_id, far_from, min_d)
	if p.x == INF:
		return null
	var ref: float = Species.DEFS[sp_id].ref_mass
	var c := spawn(sp_id, ref * randf_range(0.8, 1.15), p)
	if sp_id == "turkey":
		var best := {}
		var bd := 1e9
		for m in terrain.turkey_mounds:
			var d := p.distance_to(m.p)
			if d < bd:
				bd = d
				best = m
		c.brain.mound = best
		c.home = Vector3(best.p.x, 0, best.p.y)
	if sp_id == "eagle":
		c.flying = true
		c.fly_alt = 28.0
		c.position.y += 28.0
		c.hunger = 0.2
	if sp_id == "croc":
		c.brain.set_state("lurk")
	if sp_id == "dingo":
		c.home = Vector3(Terrain.DEN_POS.x, 0, Terrain.DEN_POS.y)
	if sp_id == "crow":
		c.home = Vector3(p.x, 0, p.y)
	return c


func _populate() -> void:
	for sp_id in POP.keys():
		for i in POP[sp_id]:
			_spawn_species(sp_id)
	# extra food around the nest for hatchlings
	for i in 10:
		var p := terrain.random_land_point(Terrain.NEST_POS, 20.0, 0.5)
		spawn("grasshopper", 0.003, p)
	for i in 3:
		spawn("skink", 0.018, terrain.random_land_point(Terrain.NEST_POS, 18.0, 0.5))
	# resident monitors
	_spawn_monitor(13.5, 1, Terrain.OUTCROP_POS + Vector2(-6, 10), 38.0, "old_king")
	_spawn_monitor(8.5, 0, Vector2(-8, 72), 26.0, "matriarch")
	_spawn_monitor(10.5, 1, Terrain.SCRUB_POS + Vector2(-10, -12), 30.0, "scrub_male")
	_spawn_monitor(2.6, 0, Vector2(36, 34), 16.0, "river_sub")
	_spawn_monitor(0.55, 1, Vector2(-104, 52), 10.0, "")
	_spawn_monitor(0.45, 0, Vector2(-30, 100), 10.0, "")
	_spawn_monitor(7.0, 1, Vector2(-20, -60), 0.0, "roamer")


func _spawn_monitor(mass: float, sex: int, p: Vector2, terr: float, tag: String) -> Creature:
	var q := terrain.random_land_point(p, 4.0, 0.4)
	var c := spawn("monitor", mass, q)
	c.sex = sex
	c.territory = terr
	c.tag = tag
	c.home = Vector3(q.x, 0, q.y)
	return c


func _respawn_tick() -> void:
	var counts := {}
	var monitors := 0
	for c in creatures:
		var cc: Creature = c
		if not cc.alive or cc.is_avatar():
			continue
		counts[cc.species_id] = counts.get(cc.species_id, 0) + 1
		if cc.species_id == "monitor":
			monitors += 1
	var focus := player.position if player != null else camera.global_position
	for sp_id in POP.keys():
		var n: int = counts.get(sp_id, 0)
		if n < POP[sp_id]:
			# repopulate gradually, out of the player's sight
			var small: bool = sp_id in ["grasshopper", "mouse", "skink", "frog", "fish"]
			var tries := 1 if not small else 3
			for k in tries:
				if randf() < 0.6:
					_spawn_species(sp_id, focus, 22.0 if small else 55.0)
	# natural deaths keep carrion in the landscape (old age, disease, heat)
	natural_t -= 8.0
	if natural_t <= 0.0:
		natural_t = randf_range(60.0, 110.0)
		var big := 0
		for cc2 in carcasses:
			if cc2.mass > 1.0:
				big += 1
		if big < 3:
			var cands: Array = []
			for c3 in creatures:
				var cc3: Creature = c3
				if cc3.alive and not cc3.is_avatar() and cc3.species_id in ["wallaby", "turkey", "wallaby", "crow"] and cc3.position.distance_to(focus) > 45.0:
					cands.append(cc3)
			if not cands.is_empty():
				var victim: Creature = cands[randi() % cands.size()]
				victim.die("Natural causes")
	# keep a little prey around a small player: insects emerge from the grass nearby
	if player != null and player.alive and player.mass < 0.6:
		var near := 0
		for o in query(player.position, 30.0):
			var oc: Creature = o
			if oc.alive and oc.species_id in ["grasshopper", "skink", "frog", "mouse"]:
				near += 1
		if near < 6:
			for k in 2:
				var a := randf() * TAU
				var q := terrain.random_land_point(Vector2(player.position.x, player.position.z) + Vector2(cos(a), sin(a)) * 22.0, 8.0, 0.3)
				if terrain.grassiness(q.x, q.y) > 0.2 or randf() < 0.3:
					var sid := "grasshopper" if randf() < 0.7 else ("skink" if player.mass < 0.15 else "mouse")
					spawn(sid, Species.DEFS[sid].ref_mass * randf_range(0.8, 1.15), q)
	if monitors < 6 and randf() < 0.25:
		var edge := Vector2(randf_range(-1, 1), randf_range(-1, 1)).normalized() * (Terrain.PLAY_HALF - 20.0)
		var p := terrain.random_land_point(edge, 20.0, 0.5)
		if Vector2(focus.x, focus.z).distance_to(p) > 60.0:
			var mass := randf_range(0.4, 11.0)
			var c := spawn("monitor", mass, p)
			c.territory = 0.0 if randf() < 0.5 else 20.0
			c.home = Vector3(p.x, 0, p.y)


# ------------------------------------------------------------------ queries

func query(pos: Vector3, r: float) -> Array:
	var out: Array = []
	var i0 := floori((pos.x - r) / GRID)
	var i1 := floori((pos.x + r) / GRID)
	var j0 := floori((pos.z - r) / GRID)
	var j1 := floori((pos.z + r) / GRID)
	var r2 := r * r
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var cell = grid.get(Vector2i(i, j))
			if cell == null:
				continue
			for c in cell:
				if not is_instance_valid(c):
					continue          # removed since the grid was built (e.g. by a network request)
				var cc: Creature = c
				if cc.removed:
					continue
				var dx := cc.position.x - pos.x
				var dz := cc.position.z - pos.z
				if dx * dx + dz * dz <= r2:
					out.append(cc)
	return out


func _rebuild_grid() -> void:
	grid.clear()
	for c in creatures:
		var cc: Creature = c
		if cc.removed:
			continue
		var key := Vector2i(floori(cc.position.x / GRID), floori(cc.position.z / GRID))
		var cell = grid.get(key)
		if cell == null:
			grid[key] = [cc]
		else:
			cell.append(cc)


func remove_creature(c: Creature) -> void:
	if c.removed:
		return
	c.removed = true
	creatures.erase(c)
	carcasses.erase(c)
	if c == player:
		return
	c.queue_free()


var kill_log := {}


func on_death(c: Creature, killer: Creature) -> void:
	var kk := (killer.species_id if killer != null else c.cause_of_death) + ">" + c.species_id
	kill_log[kk] = kill_log.get(kk, 0) + 1
	if not c.removed and c.meat > 0.0:
		carcasses.append(c)
	if killer != null and killer.is_player and player_life != null:
		player_life.on_kill(c)
	elif killer != null and killer.net_mode == 1:
		Net.send_event(killer.net_peer, "kill", c.sp.name, c.mass, 1 if c.species_id == "monitor" else 0)
	if c.is_player:
		player_died.emit(c.cause_of_death)


func on_hit(attacker: Creature, victim: Creature, dmg: float) -> void:
	if attacker.is_player and player_life != null:
		player_life.on_hit_dealt(victim, dmg)
	elif attacker.net_mode == 1 and victim.species_id == "monitor":
		Net.send_event(attacker.net_peer, "hit", "", dmg, victim.id)


# ------------------------------------------------------------------ multiplayer

func find_creature(cid: int) -> Creature:
	if cid < 0:
		return null
	if net_client:
		var p = puppets.get(cid)
		return p if p != null and is_instance_valid(p) and not p.removed else null
	for c in creatures:
		var cc: Creature = c
		if cc.id == cid and not cc.removed:
			return cc
	return null


## Host: a lizard mirroring a remote player's own simulation.
func spawn_remote_avatar(peer: int, s: PackedFloat32Array) -> Creature:
	var c := Creature.new()
	c.net_mode = 1
	c.net_peer = peer
	c.setup(self, "monitor", maxf(s[5], 0.01), Vector3(s[0], s[1], s[2]), s[3])
	c.sex = int(s[16])
	c.tag = "player"
	c.brain = Creature.NetBrain.new()
	add_child(c)
	creatures.append(c)
	c.set_net_name(Net.player_name(peer))
	return c


## Client: drop the local ecosystem; the host's animals arrive as puppets.
func enter_client_mode() -> void:
	net_client = true
	for c in creatures.duplicate():
		if c != player:
			remove_creature(c)
	carcasses.clear()
	_clear_nests()
	puppets.clear()
	_snap_serial = 0


## Back to a private world after a session (either side).
func exit_net_mode() -> void:
	var was_client := net_client
	net_client = false
	puppets.clear()
	for c in creatures.duplicate():
		var cc: Creature = c
		if cc == player:
			continue
		if was_client or cc.net_mode != 0:
			remove_creature(cc)
		elif cc.net_peer != 0:
			cc.net_peer = 0
			cc.set_net_name("")
	if was_client:
		carcasses.clear()
		_clear_nests()
		_populate()


func _clear_nests() -> void:
	for n in nests:
		if n.has("node") and is_instance_valid(n.node):
			n.node.queue_free()
	nests.clear()
	_nest_sig = ""


func refresh_net_names() -> void:
	for c in creatures:
		var cc: Creature = c
		if cc.net_peer < 0:
			cc.net_peer = Net.slot_peer(-cc.net_peer)      # names arrived after the lizard did
		if cc.net_peer != 0 and cc != player and cc.alive:
			cc.set_net_name(Net.player_name(cc.net_peer))


## Client: one snapshot from the host (records of Net.STRIDE floats).
func apply_snapshot(data: PackedFloat32Array, me: int) -> void:
	var now := Time.get_ticks_msec()
	var n := data.size() / Net.STRIDE
	for k in n:
		var o := k * Net.STRIDE
		var owner := int(data[o + 16])
		if owner == me:
			continue
		var s := data.slice(o, o + Net.STRIDE)
		var cid := int(s[0])
		var c = puppets.get(cid)
		if c == null or not is_instance_valid(c) or c.removed:
			var si := int(s[1])
			if si < 0 or si >= Net.species_list.size():
				continue
			c = Creature.new()
			c.net_mode = 2
			c.setup(self, Net.species_list[si], maxf(s[7], 0.0005), Vector3(s[2], s[3], s[4]), s[5])
			c.id = cid
			c.brain = Creature.NetBrain.new()
			add_child(c)
			creatures.append(c)
			puppets[cid] = c
			if owner != 0:
				c.net_peer = Net.slot_peer(owner)
				c.tag = "player"
				c.set_net_name(Net.player_name(c.net_peer))
		var pc: Creature = c
		pc.apply_puppet(s)
		pc.net_seen = now
	# anything the host stopped sending has left our area (or the world)
	if now - _snap_serial < 100:
		return
	_snap_serial = now
	for cid in puppets.keys():
		var pc2 = puppets[cid]
		if pc2 == null or not is_instance_valid(pc2) or pc2.removed:
			puppets.erase(cid)
		elif now - pc2.net_seen > 450:
			puppets.erase(cid)
			remove_creature(pc2)


## Client: mirror the host's monitor clutches (just the visuals).
func net_sync_nests(arr: PackedFloat32Array) -> void:
	var sig := ""
	for i in range(0, arr.size() - 3, 4):
		sig += "%d,%d,%d;" % [int(arr[i] * 10.0), int(arr[i + 2] * 10.0), int(arr[i + 3])]
	if sig == _nest_sig:
		return
	_clear_nests()
	_nest_sig = sig
	for i in range(0, arr.size() - 3, 4):
		add_nest(Vector3(arr[i], arr[i + 1], arr[i + 2]), int(arr[i + 3]), 0)


# ------------------------------------------------------------------ scent (taste the air)

func spawn_scent(p: Vector3, col: Color) -> void:
	var ps := GPUParticles3D.new()
	ps.amount = 40
	ps.lifetime = 4.0
	ps.one_shot = false
	ps.visibility_aabb = AABB(Vector3(-5, -2, -5), Vector3(10, 20, 10))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.6
	pm.direction = Vector3.UP
	pm.spread = 12.0
	pm.initial_velocity_min = 0.6
	pm.initial_velocity_max = 1.2
	pm.gravity = Vector3(0.1, 0.1, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.6
	var grad := Gradient.new()
	grad.set_color(0, Color(col.r, col.g, col.b, 0.0))
	grad.add_point(0.2, Color(col.r, col.g, col.b, 0.8))
	grad.set_color(grad.get_point_count() - 1, Color(col.r, col.g, col.b, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	ps.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.12, 0.12)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.albedo_color = Color(1, 1, 1)
	qm.material = mat
	ps.draw_pass_1 = qm
	ps.position = p + Vector3(0, 0.2, 0)
	fx_root.add_child(ps)
	ps.emitting = true
	var tw := create_tween()
	tw.tween_interval(5.0)
	tw.tween_callback(func(): ps.emitting = false)
	tw.tween_interval(4.5)
	tw.tween_callback(ps.queue_free)


# ------------------------------------------------------------------ nests (monitor eggs)

func add_nest(p: Vector3, eggs: int, lineage: int) -> void:
	nests.append({"p": p, "eggs": eggs, "t": 0.0, "lineage": lineage})
	_spawn_egg_visuals(nests.back())


func _spawn_egg_visuals(n: Dictionary) -> void:
	var mesh := Vegetation.egg_mesh()
	var holder := Node3D.new()
	holder.position = n.p
	for i in n.eggs:
		var e := MeshInstance3D.new()
		e.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.vertex_color_is_srgb = true
		e.material_override = mat
		var a: float = TAU * i / n.eggs
		e.position = Vector3(cos(a) * 0.12, 0.03, sin(a) * 0.12)
		e.scale = Vector3.ONE * 0.045
		e.rotation = Vector3(randf() * 0.5, randf() * TAU, 1.3)
		holder.add_child(e)
	fx_root.add_child(holder)
	n["node"] = holder


func _update_nests(dt: float) -> void:
	for n in nests.duplicate():
		n.t += dt
		if n.t > 300.0:
			# hatch!
			var cnt: int = n.eggs
			for i in cnt:
				var p := terrain.random_land_point(Vector2(n.p.x, n.p.z), 3.0, 0.2)
				var h := spawn("monitor", 0.04, p)
				h.tag = "offspring"
			Sfx.play_at("hatch", n.p, 0.0, 1.0, 40.0)
			if n.has("node") and is_instance_valid(n.node):
				n.node.queue_free()
			nests.erase(n)


# ------------------------------------------------------------------ main loop

func _process(delta: float) -> void:
	var dt := minf(delta, 0.2)
	frame += 1
	time += dt
	var sph := DAY_SEC_PER_HOUR if (hour >= 6.0 and hour < 19.0) else NIGHT_SEC_PER_HOUR
	var old_hour := hour
	hour += dt / sph
	if hour >= 24.0:
		hour -= 24.0
	if old_hour < 6.0 and hour >= 6.0:
		day += 1
	_update_sky(dt)
	_rebuild_grid()
	var focus := camera.global_position
	if player != null and not player.removed:
		focus = player.position
	var _t0 := Time.get_ticks_usec()
	var _tv := 0
	# creature updates with LOD
	for i in range(creatures.size() - 1, -1, -1):
		if i >= creatures.size():
			continue
		var c: Creature = creatures[i]
		if c.removed:
			continue
		var d := c.position.distance_to(focus)
		var lod := 0 if d < 55.0 else (1 if d < 110.0 else 2)
		if c.is_player:
			lod = 0
		c.lod = lod
		var step := 1 if lod == 0 else (2 if lod == 1 else 4)
		if (frame + c.id) % step == 0:
			c.tick(dt * step)
		if c.removed:
			continue
		var vis_range := 95.0
		if c.flying or c.species_id == "eagle":
			vis_range = 260.0
		elif c.mass < 0.05:
			vis_range = 30.0
		elif c.mass < 1.0:
			vis_range = 60.0
		var visible_now := d < vis_range and not c.hidden
		if c.rig.visible != visible_now:
			c.rig.visible = visible_now
		var vstep := 1 if (c.is_player or d < 4.0 + c.length * 8.0) else (2 if d < 30.0 else 3)
		if visible_now and ((frame + c.id) % vstep == 0):
			var _tv0 := Time.get_ticks_usec()
			c.update_visual(dt * vstep)
			var _dtv := Time.get_ticks_usec() - _tv0
			_tv += _dtv
			if Game.test_mode != "":
				var key: String = c.species_id + ("*" if c.is_player else "")
				perf_sp[key] = perf_sp.get(key, 0) + _dtv
	perf_acc[0] += Time.get_ticks_usec() - _t0 - _tv
	perf_acc[1] += _tv
	perf_acc[2] += 1
	if Game.test_mode != "" and perf_acc[2] >= 300:
		print("perf: sim %.2f ms  visuals %.2f ms  fps %d" % [perf_acc[0] / 1000.0 / perf_acc[2], perf_acc[1] / 1000.0 / perf_acc[2], Engine.get_frames_per_second()])
		for k in perf_sp.keys():
			perf_sp[k] = snappedf(perf_sp[k] / 1000.0 / perf_acc[2], 0.01)
		print("   per species ms/frame: ", perf_sp)
		print("   process ms %.2f  draw calls %d  objects %d  prims %dk" % [Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000)])
		perf_sp = {}
		perf_acc = [0, 0, 0]
	if player_life != null and player != null:
		player_life.update(dt)
	if not net_client:
		_update_nests(dt)
		spawn_t -= dt
		if spawn_t <= 0.0:
			spawn_t = 8.0
			_respawn_tick()
			_regen_food()
	_update_ambience(dt)
	pollen.global_position = focus + Vector3(0, 1.5, 0)
	pollen.emitting = not is_night()
	var water_near := terrain.moisture(focus.x, focus.z) > 0.4
	fireflies.emitting = is_night() and water_near
	fireflies.global_position = focus


func _regen_food() -> void:
	for m in terrain.turkey_mounds:
		if m.eggs < 4:
			m.regen += 8.0
			if m.regen > 90.0:
				m.regen = 0.0
				m.eggs += 1


func _update_ambience(dt: float) -> void:
	ambience_t -= dt
	if ambience_t > 0.0:
		return
	ambience_t = 0.25
	var focus := camera.global_position
	var night := is_night()
	var dawn_dusk := (hour > 5.0 and hour < 7.0) or (hour > 18.0 and hour < 20.0)
	Sfx.set_bed("amb_day", 0.0 if night else (0.55 if dawn_dusk else 0.8))
	Sfx.set_bed("amb_night", 0.8 if night else (0.35 if dawn_dusk else 0.0))
	var alt := focus.y - terrain.height(focus.x, focus.z)
	Sfx.set_bed("wind", clampf(0.25 + (focus.y / 25.0) * 0.4 + alt * 0.02, 0.2, 0.8))
	var rd := terrain.rd_at(focus.x, focus.z) - terrain.river_width(focus.x, focus.z)
	Sfx.set_bed("river", clampf(1.0 - rd / 35.0, 0.0, 0.9))
	# random distant birdsong
	if not night and randf() < 0.08:
		var p := focus + Vector3(randf_range(-40, 40), 5.0, randf_range(-40, 40))
		Sfx.play_at("bird", p, -8.0, randf_range(0.9, 1.2), 70.0)
