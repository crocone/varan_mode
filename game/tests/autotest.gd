extends Node
## Automated test / screenshot harness. Run with:  -- --test=shots  (or --test=sim)

var main: Node
var world: World
var shots_dir := ""


func run(m: Node) -> void:
	main = m
	world = m.world
	shots_dir = ProjectSettings.globalize_path("res://").path_join("../tools/shots/")
	DirAccess.make_dir_recursive_absolute(shots_dir)
	match Game.test_mode:
		"shots":
			await _shots()
		"sim":
			await _sim()
		"rig":
			await _rig()
		"play":
			await _play()
		"climb":
			await _climb_test()
		"save":
			await _save_test()
		"slope":
			await _slope_test()
		"repro":
			await _repro_test()
		"export_parts":
			_export_parts()
		"perf":
			var pf = load("res://tests/perf.gd").new()
			add_child(pf)
			await pf.run(main)
		"zoo2":
			var z2 = load("res://tests/zoo2.gd").new()
			add_child(z2)
			await z2.run(main)
		"zoo":
			var z = load("res://tests/zoo.gd").new()
			add_child(z)
			await z.run(main)
		"territory":
			await _territory_test()
		"mpmenu":
			main.go_menu()
			await _wait(3.0)
			main.menus.open_multiplayer()
			await _wait(0.5)
			await _shot("mp_menu")
			Game.settings.net_port = 24588
			main.host_game(false)
			await _hatched()
			await _wait(1.0)
			main.pause()
			await _wait(0.5)
			await _shot("mp_pause")
			main.unpause()
			world.player.die("Lace Monitor")
			await _wait(4.0)
			await _shot("mp_death")
		"nethost", "netjoin":
			var nt = load("res://tests/nettest.gd").new()
			add_child(nt)
			await nt.run(main, self)
		"menu":
			main.go_menu()
			await _wait(4.0)
			await _shot("menu")
	get_tree().quit()


func _hatched() -> void:
	for i in 100:
		if main.state == "playing":
			break
		await _wait(0.2)
	await _wait(0.3)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec, true, false, true).timeout


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(shots_dir + name + ".png")
	print("shot: ", name)


func _place_player(p2: Vector2, mass: float, yaw := 0.0) -> void:
	var p: Creature = world.player
	p.set_mass(mass)
	p.health = p.max_health
	p.position = Vector3(p2.x, world.terrain.height(p2.x, p2.y), p2.y)
	p.yaw = yaw
	p.rig.reset_chain()
	world.camera.yaw = yaw + PI + 0.5
	world.camera.pitch = -0.25
	world.camera.pivot = p.position


func _shots() -> void:
	main.go_menu()
	await _wait(3.0)
	await _shot("00_menu")
	main.start_new_life()
	world.player.invulnerable = true
	await _hatched()
	await _shot("01_hatching")
	await _wait(3.5)
	await _shot("02_hatched")
	var p: Creature = world.player
	p.steer(p.fwd(), p.walk_speed())
	await _wait(1.2)
	await _shot("03_walk_hatchling")
	p.halt()
	world.hour = 11.0
	_place_player(Vector2(-40, 60), 0.4, 0.8)
	await _wait(1.0)
	await _shot("04_juvenile_billabong")
	_place_player(Terrain.OUTCROP_POS + Vector2(-10, 20), 3.0, 2.0)
	p.steer(p.fwd(), p.run_speed())
	await _wait(1.0)
	await _shot("05_subadult_run")
	p.halt()
	_place_player(Vector2(10, 40), 10.0, -1.0)
	p.posturing = true
	await _wait(1.0)
	await _shot("06_adult_posture")
	p.posturing = false
	world.camera.zoom = 0.6
	world.camera.pitch = -0.1
	await _wait(0.6)
	await _shot("07_adult_close")
	world.camera.zoom = 1.0
	world.hour = 18.4
	world.camera.pitch = -0.05
	await _wait(1.0)
	await _shot("08_sunset")
	world.hour = 22.0
	await _wait(1.0)
	await _shot("09_night")
	world.hour = 9.0
	# look around at wildlife
	var found := 0
	for sp_id in ["dingo", "wallaby", "croc", "turkey", "mouse", "skink", "crow"]:
		for c in world.creatures:
			var cc: Creature = c
			if cc.alive and cc.species_id == sp_id and not cc.is_player:
				var off := Vector2(cc.length * 3.0 + 1.0, cc.length * 2.0 + 0.5)
				_place_player(Vector2(cc.position.x, cc.position.z) + off, 3.0, atan2(-off.x, -off.y))
				world.camera.zoom = 0.8
				await _wait(0.8)
				await _shot("10_" + sp_id)
				found += 1
				break
	print("DONE shots, fps=", Engine.get_frames_per_second(), " creatures=", world.creatures.size())


func _sim() -> void:
	main.start_new_life()
	await _hatched()
	world.player.brain.enabled = false
	world.player.iframes = 1e9
	Engine.time_scale = 6.0
	var t0 := Time.get_ticks_msec()
	for k in 12:
		await _wait(10.0)
		Engine.time_scale = 6.0
		var counts := {}
		for c in world.creatures:
			var cc: Creature = c
			var key: String = cc.species_id + ("" if cc.alive else "(dead)")
			counts[key] = counts.get(key, 0) + 1
		var states := {}
		for c in world.creatures:
			var cc: Creature = c
			if cc.alive and cc.brain is Brain:
				var s: String = cc.species_id + ":" + cc.brain.state
				states[s] = states.get(s, 0) + 1
		print("t=%.0f day=%d hour=%.1f fps=%d scale=%.1f" % [world.time, world.day, world.hour, Engine.get_frames_per_second(), Engine.time_scale])
		print("  counts ", counts)
		print("  states ", states)
		print("  player alive=", world.player.alive, " hp=", world.player.health_frac())
	Engine.time_scale = 1.0


func _cam(from: Vector3, to: Vector3) -> void:
	world.camera.mode = "manual"
	world.camera.cam.global_transform = Transform3D(Basis.looking_at(to - from, Vector3.UP), from)


func _rig() -> void:
	if "noglow" in Game.cmd_args:
		world.env.glow_enabled = false
	main.start_new_life()
	await _hatched()
	world.hour = 10.5
	var p: Creature = world.player
	var spot := Vector2(-40, 90)
	for m in [0.04, 1.0, 10.0]:
		_place_player(spot, m, 0.0)
		p.halt()
		var L := p.length
		var c := p.position
		await _wait(0.5)
		_cam(c + Vector3(L * 1.1, L * 0.5, L * 0.2), c + Vector3(0, 0, -L * 0.2))
		await _wait(0.3)
		await _shot("rig_side_%s" % str(m))
		_cam(c + Vector3(0.01, L * 1.6, -L * 0.25), c + Vector3(0, 0, -L * 0.25))
		await _wait(0.2)
		await _shot("rig_top_%s" % str(m))
	# walking and running at adult size
	p.steer(Vector3(0, 0, 1), p.walk_speed())
	await _wait(1.0)
	var L2 := p.length
	_cam(p.position + Vector3(L2 * 1.3, L2 * 0.6, L2 * 0.4), p.position)
	await _shot("rig_walk")
	p.steer(Vector3(1, 0, 0), p.run_speed())
	await _wait(0.6)
	_cam(p.position + Vector3(0.2, L2 * 0.8, L2 * 1.5), p.position)
	await _shot("rig_run_turn")
	p.halt()
	p.posturing = true
	await _wait(1.0)
	_cam(p.position + Vector3(L2 * 1.0, L2 * 0.4, L2 * 0.9), p.position + Vector3(0, L2 * 0.1, 0))
	await _shot("rig_posture")
	p.posturing = false
	p.try_bite()
	await _wait(0.15)
	await _shot("rig_bite")
	await _wait(1.0)
	p.try_whip()
	await _wait(0.25)
	await _shot("rig_whip")


class Bot:
	var c: Creature
	var w: World
	var look_point = null
	var tongue_now := false
	var enabled := true
	var interact_hint := ""
	var interact_kind := ""
	var target: Creature = null
	var goal := Vector3.INF
	var wgoal := Vector3.INF
	var t := 0.0
	var stuck := 0.0
	var thirst_t := 0.0
	var log_t := 0.0

	func _init(cr: Creature) -> void:
		c = cr
		w = cr.world

	func update(dt: float) -> void:
		t += dt
		var life: PlayerLife = w.player_life
		if c.action != "":
			c.halt()
			return
		# drink when thirsty
		if c.blocked:
			stuck += dt
			if stuck > 2.0:
				goal = Vector3.INF
				wgoal = Vector3.INF
				target = null
				stuck = 0.0
				c.position += Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)) * c.length
		if life.water < 35.0:
			thirst_t += dt
			if thirst_t > 40.0 and wgoal != Vector3.INF and wgoal.y > -900.0:
				# navigation fallback for the test bot only
				c.position = Vector3(wgoal.x, w.terrain.height(wgoal.x, wgoal.z), wgoal.z)
				c.rig.reset_chain()
				thirst_t = 0.0
				print("  bot teleported to water")
			if wgoal == Vector3.INF or wgoal.y < -900.0:
				wgoal = w.terrain.nearest_shore(Vector2(c.position.x, c.position.z), 120.0)
				print("  bot seeks water at ", wgoal, " dist ", c.position.distance_to(wgoal))
			goal = wgoal
			var probe := c.head_pos() + c.fwd() * (c.reach() + c.length * 0.25 + 0.08)
			if w.terrain.water_depth(probe.x, probe.z) > 0.005 or w.terrain.water_depth(c.position.x, c.position.z) > -0.02:
				c.halt()
				var okd := c.start_drink()
				if int(t) % 5 == 0:
					print("  bot drink start ", okd, " action=", c.action, " water=", life.water)
				return
			if c.position.distance_to(goal) < 1.5:
				# face the water
				for k in 12:
					var a := TAU * k / 12.0
					var q := c.position + Vector3(cos(a), 0, sin(a)) * 2.0
					if w.terrain.water_depth(q.x, q.z) > 0.02:
						c.steer(q - c.position, c.walk_speed() * 0.5)
						return
			_go(goal, c.walk_speed() * 1.5)
			return
		# sleep at night
		if w.is_night():
			c.halt()
			c.resting = true
			return
		c.resting = false
		thirst_t = 0.0
		if wgoal != Vector3.INF:
			wgoal = Vector3.INF
			goal = Vector3.INF
		# eat nearby carcass
		for o in w.query(c.head_pos(), c.reach() + 1.0):
			var oc: Creature = o
			if not oc.alive and oc.meat > 0.0 and oc.carried_by == null and not life.is_full():
				if c.head_pos().distance_to(oc.position) < c.reach() + oc.length * 0.4 + 0.2:
					c.halt()
					c.start_eat(oc)
					return
				_go(oc.position, c.walk_speed())
				return
		# scavenge / raid eggs when hungry
		if life.food < 70.0 and not life.is_full():
			var best: Creature = null
			var bd2 := 90.0
			for carc in w.carcasses:
				var cc: Creature = carc
				if not cc.removed and cc.meat > c.mass * 0.05:
					var dd := c.position.distance_to(cc.position)
					if dd < bd2:
						bd2 = dd
						best = cc
			if best != null:
				if c.head_pos().distance_to(best.position) < c.reach() + best.length * 0.4 + 0.2:
					c.halt()
					c.start_eat(best)
				else:
					_go(best.position, c.walk_speed() * 1.3)
				return
			if c.mass >= 0.18:
				for m in w.terrain.turkey_mounds:
					if m.eggs > 0 and Vector2(c.position.x, c.position.z).distance_to(m.p) < 70.0:
						var mp := Vector3(m.p.x, c.position.y, m.p.y)
						if c.position.distance_to(mp) < m.r + c.length * 0.5:
							c.halt()
							c.start_eat(m)
						else:
							_go(mp, c.walk_speed() * 1.3)
						return
		# hunt
		if target == null or not is_instance_valid(target) or not target.alive or target.removed or c.position.distance_to(target.position) > 40.0:
			target = null
			var bd := 40.0
			for o in w.query(c.position, 40.0):
				var oc2: Creature = o
				if c.can_hunt(oc2) and not oc2.sheltered and oc2.mass > c.mass * 0.01:
					var d := c.position.distance_to(oc2.position)
					if d < bd:
						bd = d
						target = oc2
		if target != null and not life.is_full():
			var d2 := c.head_pos().distance_to(target.position)
			if d2 < c.reach() * 1.5 + target.radius + 0.05:
				c.halt()
				c.try_bite()
			else:
				c.sprinting = d2 < 4.0
				_go(target.position, c.run_speed() if c.sprinting else c.walk_speed())
			return
		# wander
		if goal == Vector3.INF or c.position.distance_to(goal) < 2.0:
			var p := w.terrain.random_land_point(Vector2(c.position.x, c.position.z), 30.0, 0.4)
			goal = Vector3(p.x, 0, p.y)
		_go(goal, c.walk_speed())

	func _go(p: Vector3, spd: float) -> void:
		var d := p - c.position
		d.y = 0
		if c.blocked:
			d = d.rotated(Vector3.UP, 1.2)
		c.steer(d, spd)


func _play() -> void:
	main.start_new_life()
	await _hatched()
	var p: Creature = world.player
	p.brain = Bot.new(p)
	var life: PlayerLife = world.player_life
	if "god" in Game.cmd_args:
		p.invulnerable = true
	Engine.time_scale = 4.0
	for k in 200:
		await _wait(5.0)
		if not p.alive:
			print("BOT DIED: ", p.cause_of_death, " at age ", life.age_t)
			break
		Engine.time_scale = (8.0 if "fast" in Game.cmd_args else 4.0) if not life.sleeping else 7.0
		if k % 10 == 0:
			print("  kills: ", world.kill_log, " carcasses ", world.carcasses.size())
		print("age=%.0f day=%d h=%.1f stage=%s mass=%.3f food=%.0f water=%.0f temp=%.1f hp=%.2f eaten=%d kills=%d" % [life.age_t, world.day, world.hour, life.stage_name(), p.mass, life.food, life.water, life.body_temp, p.health_frac(), life.stats.eaten, life.stats.kills])
	Engine.time_scale = 1.0


func _climb_test() -> void:
	main.start_new_life()
	await _hatched()
	world.hour = 10.0
	var p: Creature = world.player
	var tr: Dictionary = world.terrain.nearest_tree(Vector2(-60, 60), 80.0)
	var tp: Vector2 = tr.p
	_place_player(tp + Vector2(tr.r0 + 0.6, 0.0), 1.0, -PI * 0.5)
	await _wait(0.5)
	var ok := p.start_climb(tr)
	print("climb started: ", ok, " tree h=", tr.height, " r0=", tr.r0)
	p.brain.enabled = false
	p.climb_in = Vector2(0, 1)
	await _wait(1.5)
	p.climb_in = Vector2.ZERO
	var L := p.length
	var c0 := p.position
	var out := Vector3(cos(p.climb_ang), 0, sin(p.climb_ang))
	var sd := out.cross(Vector3.UP)
	_cam(c0 + sd * L * 1.4 + out * L * 0.9 + Vector3.UP * L * 0.1, c0 - Vector3.UP * L * 0.2)
	await _wait(0.3)
	await _shot("climb_side")
	_cam(c0 + out * L * 1.8 + Vector3.UP * L * 0.3, c0 - Vector3.UP * L * 0.1)
	await _wait(0.2)
	await _shot("climb_back")
	p.climb_in = Vector2(0.6, 1)
	await _wait(0.4)
	c0 = p.position
	out = Vector3(cos(p.climb_ang), 0, sin(p.climb_ang))
	sd = out.cross(Vector3.UP)
	_cam(c0 + sd * L * 1.4 + out * L * 0.9, c0)
	await _shot("climb_moving")
	print("climb_h=", p.climb_h)


func _save_test() -> void:
	main.start_new_life()
	await _hatched()
	var p: Creature = world.player
	var life: PlayerLife = world.player_life
	_place_player(Vector2(20, 60), 2.3, 1.0)
	life.age_t = 700.0
	life.food = 42.0
	life.water = 33.0
	life.stats.kills = 7
	world.hour = 15.5
	await _wait(0.5)
	var before := [p.mass, p.position, life.stage_name(), life.food, world.hour]
	print("main state: ", main.state, " alive ", p.alive, " player==world.player ", p == world.player)
	print("save ok: ", main.autosave(), " before: ", before)
	main.go_menu()
	await _wait(1.0)
	print("has save: ", Game.has_save())
	main.continue_life()
	await _wait(1.0)
	var p2: Creature = world.player
	var l2: PlayerLife = world.player_life
	var after := [p2.mass, p2.position, l2.stage_name(), l2.food, world.hour]
	print("after:  ", after, " kills=", l2.stats.kills, " age=", l2.age_t)
	var ok: bool = absf(p2.mass - before[0]) < 0.001 and p2.position.distance_to(before[1]) < 0.5 and l2.stage_name() == before[2]
	print("SAVE/LOAD ", "PASS" if ok else "FAIL")
	await _shot("save_loaded")
	# pause menu & settings screenshots
	main.pause()
	await _wait(0.5)
	await _shot("ui_pause")
	main.menus.open_settings(func(): main.menus.show_only(main.menus.pause_panel))
	await _wait(0.3)
	await _shot("ui_settings")
	main.unpause()
	# die -> death screen
	p2.die("Dingo")
	await _wait(4.0)
	await _shot("ui_death")


func _territory_test() -> void:
	main.start_new_life()
	await _hatched()
	var king: Creature = null
	for c in world.creatures:
		if c.tag == "old_king":
			king = c
	var p: Creature = world.player
	p.invulnerable = true
	world.hour = 10.0
	var kp := Vector2(king.position.x, king.position.z)
	# similar-size rival walking into the territory
	_place_player(kp + Vector2(6, 0), 11.0, -PI * 0.5)
	p.brain.enabled = false
	var seen := {}
	for k in 40:
		await _wait(0.25)
		p.steer((king.position - p.position), p.walk_speed() * 0.4)
		seen[king.brain.state] = seen.get(king.brain.state, 0) + 1
		if k == 12:
			world.camera.yaw = p.yaw + PI + 0.8
			await _shot("territory_posture")
	print("old king states vs similar rival: ", seen)
	# small intruder
	_place_player(kp + Vector2(7, 0), 1.0, -PI * 0.5)
	seen = {}
	for k in 30:
		await _wait(0.25)
		p.steer((king.position - p.position), p.walk_speed() * 0.5)
		seen[king.brain.state] = seen.get(king.brain.state, 0) + 1
	print("old king states vs small intruder: ", seen)
	print("king pos ", king.position, " player ", p.position, " d=", king.position.distance_to(p.position), " terr ", king.territory, " home ", king.home, " vis ", p.visibility, " sex k/p ", king.sex, "/", p.sex)


func _slope_test() -> void:
	main.start_new_life()
	await _hatched()
	world.hour = 10.0
	var p: Creature = world.player
	p.invulnerable = true
	p.brain.enabled = false
	# walk up the outcrop slope
	var start := Terrain.OUTCROP_POS + Vector2(-34, 0)
	_place_player(start, 0.06, PI * 0.5)
	var worst := 0.0
	for k in 60:
		p.steer(Vector3(1, 0, 0.1), p.walk_speed())
		await _wait(0.05)
		# check body clearance at chain points
		for i in p.rig.n_pts:
			var q: Vector3 = p.rig.vis[i]
			var gy: float = world.terrain.height(q.x, q.z)
			var bottom: float = q.y - p.rig.prof_h[i] * p.length * 0.62
			worst = minf(worst, bottom - gy)
		if k == 30:
			var L := p.length
			_cam(p.position + Vector3(L * 0.2, L * 0.25, L * 1.6), p.position)
			await _shot("slope_side")
	print("slope worst clearance (m): ", worst, "  L=", p.length)
	# over a basking slab
	var s: Dictionary = world.terrain.nearest_slab(Terrain.NEST_POS, 40.0)
	_place_player(s.p - Vector2(s.rx + 0.6, 0), 0.06, PI * 0.5)
	worst = 0.0
	for k in 60:
		p.steer(Vector3(1, 0, 0), p.walk_speed())
		await _wait(0.05)
		for i in p.rig.n_pts:
			var q: Vector3 = p.rig.vis[i]
			var gy: float = world.terrain.height(q.x, q.z)
			worst = minf(worst, q.y - p.rig.prof_h[i] * p.length * 0.62 - gy)
		if k == 25:
			var L2 := p.length
			_cam(p.position + Vector3(L2 * 0.2, L2 * 0.3, L2 * 1.6), p.position)
			await _shot("slab_side")
	print("slab worst clearance (m): ", worst)


func _repro_test() -> void:
	main.start_new_life()
	await _hatched()
	world.hour = 9.0
	var p: Creature = world.player
	var life: PlayerLife = world.player_life
	p.invulnerable = true
	p.brain.enabled = false
	p.sex = 0
	_place_player(Vector2(-40, 90), 9.0, 0.0)
	life.age_t = 1500.0
	life.food = 80.0
	await _wait(0.5)
	print("stage ", life.stage_name(), " can_court ", life.can_court())
	var partner := world.spawn("monitor", 9.0, Vector2(-40, 91.5))
	partner.sex = 1
	await _wait(0.3)
	print("court start ", p.start_court(partner))
	await _wait(3.5)
	print("gravid ", life.gravid)
	if not life.gravid:
		life.on_courted(partner)
		print("forced courtship, gravid ", life.gravid)
	var m: Dictionary = world.terrain.nearest_mound(Vector2(p.position.x, p.position.z), 200.0)
	life.lay_eggs(m)
	print("nests ", world.nests.size(), " offspring ", life.stats.offspring)
	Engine.time_scale = 8.0
	await _wait(42.0)
	Engine.time_scale = 1.0
	var kids := 0
	for c in world.creatures:
		if c.tag == "offspring":
			kids += 1
	print("hatched offspring alive: ", kids, " nests left ", world.nests.size())
	p.invulnerable = false
	p.die("Old age")
	await _wait(4.0)
	print("lineage available: ", main.has_lineage())
	main.continue_lineage()
	await _hatched()
	print("new player mass ", world.player.mass, " lineage ", world.player_life.lineage, " state ", main.state)


func _export_parts() -> void:
	PartSkin.disabled = true
	var dir := ProjectSettings.globalize_path("res://").path_join("../tools/rig_export/")
	DirAccess.make_dir_recursive_absolute(dir)
	for sp_id in ["dingo", "wallaby", "mouse", "turkey", "crow", "eagle", "frog", "grasshopper", "fish"]:
		var c := Creature.new()
		c.setup(world, sp_id, Species.DEFS[sp_id].ref_mass, Vector3(0, 60, 0), 0.0)
		var list: Array = []
		PartSkin.collect_parts(c.rig, list)
		var parts: Array = []
		for i in list.size():
			var mi: MeshInstance3D = list[i]
			var xf := PartSkin._rel(c.rig, mi)
			var arr := mi.mesh.surface_get_arrays(0)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var col = arr[Mesh.ARRAY_COLOR]
			var idx = arr[Mesh.ARRAY_INDEX]
			var vf: Array = []
			var nf: Array = []
			var cf: Array = []
			for j in v.size():
				var p := xf * v[j]
				vf.append_array([snappedf(p.x, 0.00001), snappedf(p.y, 0.00001), snappedf(p.z, 0.00001)])
				var nn := (xf.basis * n[j]).normalized() if n.size() > j else Vector3.UP
				nf.append_array([snappedf(nn.x, 0.001), snappedf(nn.y, 0.001), snappedf(nn.z, 0.001)])
				if col != null and (col as PackedColorArray).size() > j:
					var cc: Color = col[j]
					cf.append_array([snappedf(cc.r, 0.001), snappedf(cc.g, 0.001), snappedf(cc.b, 0.001)])
			var ia: Array = []
			if idx != null:
				ia = Array(idx)
			parts.append({"name": PartSkin.part_name(i, mi), "key": mi.mesh.resource_name,
				"origin": [xf.origin.x, xf.origin.y, xf.origin.z],
				"axis_y": [xf.basis.y.x, xf.basis.y.y, xf.basis.y.z],
				"basis": [xf.basis.x.x, xf.basis.x.y, xf.basis.x.z, xf.basis.y.x, xf.basis.y.y, xf.basis.y.z, xf.basis.z.x, xf.basis.z.y, xf.basis.z.z],
				"parent_node": str(mi.get_parent().name), "pivot_origin": [PartSkin._rel(c.rig, mi.get_parent()).origin.x, PartSkin._rel(c.rig, mi.get_parent()).origin.y, PartSkin._rel(c.rig, mi.get_parent()).origin.z],
				"v": vf, "n": nf, "c": cf, "i": ia})
		var f := FileAccess.open(dir + sp_id + ".json", FileAccess.WRITE)
		f.store_string(JSON.stringify({"species": sp_id, "length": c.length, "parts": parts}))
		f.close()
		print("exported ", sp_id, " parts=", parts.size())
		c.free()
	PartSkin.disabled = false
