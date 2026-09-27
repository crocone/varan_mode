extends Node
## Application flow: loading -> main menu (living world behind it) -> hatching
## -> playing <-> paused -> death -> new life / lineage / menu.

var world: World
var menus: Menus
var hud: Hud = null
var state := "loading"
var hatch_fx: Node3D = null
var _death_timer := -1.0
var _host_continue := false


func _ready() -> void:
	Game.main = self
	process_mode = Node.PROCESS_MODE_ALWAYS
	menus = Menus.new()
	add_child(menus)
	menus.new_life.connect(func(): start_new_life())
	menus.continue_life.connect(continue_life)
	menus.continue_lineage.connect(continue_lineage)
	menus.resume.connect(unpause)
	menus.save_now.connect(func():
		var ok := autosave()
		menus.save_status.text = "Saved." if ok else "Could not save.")
	menus.to_menu.connect(func():
		if state == "paused" or state == "playing":
			autosave()
		go_menu())
	menus.unstuck.connect(_unstuck)
	menus.host_game.connect(host_game)
	menus.join_game.connect(join_game)
	menus.host_now.connect(func(): host_game(true, true))
	Net.session_started.connect(_on_net_started)
	Net.session_ended.connect(_on_net_ended)
	Net.status.connect(func(t): menus.set_net_status(t))
	Net.players_changed.connect(func():
		if hud != null:
			hud.refresh_players())
	await get_tree().process_frame
	await get_tree().process_frame
	world = World.new()
	world.name = "World"
	add_child(world)
	world.process_mode = Node.PROCESS_MODE_PAUSABLE
	world.build(Game.settings.quality)
	world.apply_quality(Game.settings.quality)
	world.player_died.connect(_on_player_died)
	if Game.test_mode != "" and ResourceLoader.exists("res://tests/autotest.gd"):
		var t = load("res://tests/autotest.gd").new()
		add_child(t)
		t.run(self)
		return
	go_menu()


# ------------------------------------------------------------------ states

func go_menu() -> void:
	state = "menu"
	if Net.active:
		Net.leave()          # _on_net_ended restores a private world
	get_tree().paused = false
	Engine.time_scale = 1.0
	_remove_player()
	world.camera.orbit(Vector3(Terrain.POND_POS.x, 0.0, Terrain.POND_POS.y))
	menus.refresh_main()
	menus.show_only(menus.main_panel)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Sfx.set_bed("music_menu", 0.85)
	Sfx.set_bed("heartbeat", 0.0)


func _remove_player() -> void:
	if hud != null:
		hud.queue_free()
		hud = null
	if world.player != null:
		var p := world.player
		world.player = null
		world.player_life = null
		if not p.removed:
			world.remove_creature(p)
		p.queue_free()
	if hatch_fx != null and is_instance_valid(hatch_fx):
		hatch_fx.queue_free()
		hatch_fx = null


func _spawn_player(mass: float, pos: Vector3, yaw: float, data: Dictionary) -> Creature:
	Net.my_life += 1
	var p := Creature.new()
	p.is_player = true
	p.setup(world, "monitor", mass, pos, yaw)
	if data.has("sex"):
		p.sex = int(data.sex)
	p.brain = PlayerController.new(p)
	world.add_child(p)
	world.creatures.append(p)
	world.player = p
	var life := PlayerLife.new()
	life.setup(p, world, data)
	if data.has("health_frac"):
		p.health = p.max_health * clampf(data.health_frac, 0.05, 1.0)
	if data.has("stamina"):
		p.stamina = data.stamina
	world.player_life = life
	hud = Hud.new()
	add_child(hud)
	hud.setup(world, p, life)
	world.camera.follow(p)
	return p


func start_new_life(at: Vector3 = Vector3.INF, lineage := 1) -> void:
	_remove_player()
	menus.hide_all()
	Sfx.set_bed("music_menu", 0.0)
	get_tree().paused = false
	if not Net.active:
		# the shared clock is the host's business online
		Engine.time_scale = 1.0
		if lineage == 1:
			world.hour = 7.2
		elif world.hour > 17.0 or world.hour < 6.0:
			world.hour = 7.2
			world.day += 1
	var base := at
	if base == Vector3.INF:
		var m: Dictionary = world.terrain.mounds[0]
		var ang := PI * 0.5 if not Net.active else randf_range(0.0, TAU)
		var off: Vector2 = Vector2(cos(ang), sin(ang)) * (m.r + 0.35)
		base = Vector3(m.p.x + off.x, 0.0, m.p.y + off.y)
	base.y = world.terrain.height(base.x, base.z)
	var p := _spawn_player(0.04, base, 0.0, {"lineage": lineage})
	world.player_life.lineage = lineage
	p.sex = randi() % 2
	# hatch sequence: player waits inside the egg
	state = "hatching"
	p.hidden = true
	p.brain.enabled = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	hatch_fx = _make_egg(base)
	world.fx_root.add_child(hatch_fx)
	# siblings hatch too (online, the host's world owns every animal)
	for i in (3 if not Net.is_client() else 0):
		var q := world.terrain.random_land_point(Vector2(base.x, base.z), 1.5, 0.3)
		var s := world.spawn("monitor", randf_range(0.035, 0.045), q)
		s.tag = "sibling"
		s.home = Vector3(q.x, 0, q.y)
	var tw := create_tween()
	for k in 5:
		tw.tween_callback(func():
			Sfx.play_at("egg_crack", base, -2.0, randf_range(0.9, 1.2), 15.0)
			if hatch_fx != null and is_instance_valid(hatch_fx):
				hatch_fx.rotation = Vector3(randf_range(-0.25, 0.25), 0, randf_range(-0.25, 0.25)))
		tw.tween_interval(0.55)
	tw.tween_callback(_finish_hatch)


func _make_egg(pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos + Vector3(0, 0.035, 0)
	var e := MeshInstance3D.new()
	e.mesh = Vegetation.egg_mesh()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.6
	e.material_override = mat
	e.scale = Vector3.ONE * 0.04
	n.add_child(e)
	return n


func _finish_hatch() -> void:
	if world.player == null:
		return
	Sfx.play_at("hatch", world.player.position, 0.0, 1.0, 20.0)
	if hatch_fx != null and is_instance_valid(hatch_fx):
		var shards := CPUParticles3D.new()
		shards.one_shot = true
		shards.amount = 16
		shards.lifetime = 1.4
		shards.explosiveness = 1.0
		shards.direction = Vector3.UP
		shards.spread = 70.0
		shards.initial_velocity_min = 0.4
		shards.initial_velocity_max = 0.9
		shards.gravity = Vector3(0, -3.0, 0)
		var qm := BoxMesh.new()
		qm.size = Vector3(0.012, 0.002, 0.01)
		var sm := StandardMaterial3D.new()
		sm.albedo_color = Color(0.93, 0.9, 0.82)
		qm.material = sm
		shards.mesh = qm
		shards.position = hatch_fx.position
		world.fx_root.add_child(shards)
		shards.emitting = true
		get_tree().create_timer(3.0).timeout.connect(shards.queue_free)
		hatch_fx.queue_free()
		hatch_fx = null
	world.player.hidden = false
	world.player.brain.enabled = true
	state = "playing"
	hud.show_message("You break free of the shell. The world is enormous." if not Net.active else "You break free of the shell. Other monitors hatched into this world too.")
	autosave()


func continue_life() -> void:
	var d := Game.read_save()
	if d.is_empty() or not d.has("mass"):
		start_new_life()
		return
	_remove_player()
	menus.hide_all()
	Sfx.set_bed("music_menu", 0.0)
	get_tree().paused = false
	if not Net.is_client():
		world.hour = d.get("hour", 8.0)
		world.day = int(d.get("day", 1))
		for n in world.nests:
			if n.has("node") and is_instance_valid(n.node):
				n.node.queue_free()
		world.nests.clear()
		for n in d.get("nests", []):
			world.add_nest(Vector3(n.p[0], n.p[1], n.p[2]), int(n.eggs), int(n.lineage))
			world.nests.back().t = n.get("t", 0.0)
	var pa: Array = d.pos
	var pos := Vector3(pa[0], pa[1], pa[2])
	pos.y = world.terrain.height(pos.x, pos.z)
	_spawn_player(float(d.mass), pos, float(d.get("yaw", 0.0)), d)
	state = "playing"
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	hud.show_message("Day %d. Your life continues." % world.day)


func continue_lineage() -> void:
	if Net.is_client():
		start_new_life()
		return
	var life := world.player_life
	var gen := (life.lineage if life != null else 1) + 1
	var stats_off := 0
	# prefer a living offspring; otherwise hatch from a nest
	var heir: Creature = null
	for c in world.creatures:
		var cc: Creature = c
		if cc.alive and cc.tag == "offspring" and not cc.is_player:
			heir = cc
			break
	if heir != null:
		var pos := heir.position
		var mass := heir.mass
		world.remove_creature(heir)
		_remove_player()
		menus.hide_all()
		_spawn_player(mass, pos, heir.yaw, {"lineage": gen})
		world.player_life.lineage = gen
		world.player_life.age_t = heir.age_t
		state = "playing"
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		hud.show_message("Generation %d. You are one of your parent's young." % gen)
		return
	if not world.nests.is_empty():
		var n: Dictionary = world.nests[0]
		var p: Vector3 = n.p
		if n.has("node") and is_instance_valid(n.node):
			n.node.queue_free()
		world.nests.erase(n)
		start_new_life(p + Vector3(0.3, 0, 0.3), gen)
		return
	start_new_life()


func has_lineage() -> bool:
	if Net.is_client():
		return false
	if not world.nests.is_empty():
		return true
	for c in world.creatures:
		var cc: Creature = c
		if cc.alive and cc.tag == "offspring":
			return true
	return false


func _on_player_died(cause: String) -> void:
	print("PLAYER DIED: ", cause, " t=", world.time, " killer=", world.player.killer_name)
	state = "dead"
	Engine.time_scale = 1.0
	Sfx.set_bed("heartbeat", 0.0)
	Sfx.play("death", -2.0)
	Game.delete_save()
	Net.notify_died(cause)
	world.camera.death_view(world.player)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if hud != null:
		hud.hidden_hud = true
	_death_timer = 3.0


func _process(delta: float) -> void:
	if _death_timer > 0.0:
		_death_timer -= delta / maxf(Engine.time_scale, 0.001)
		if _death_timer <= 0.0 and state == "dead" and world.player_life != null:
			menus.show_death(world.player.cause_of_death, world.player_life, has_lineage())
			Sfx.set_bed("music_menu", 0.6)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		if state == "playing":
			pause()
		elif state == "paused":
			if menus.settings_panel.visible:
				menus.show_only(menus.pause_panel)
			else:
				unpause()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("toggle_hud") and hud != null and state == "playing":
		hud.hidden_hud = not hud.hidden_hud
	elif event is InputEventMouseButton and event.pressed and state == "playing" and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and state == "playing" and Game.test_mode == "" and not Net.active:
		pause()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST and (state == "playing" or state == "paused"):
		autosave()


func pause() -> void:
	state = "paused"
	if hud != null:
		hud.visible = false
	# online the world keeps running; the lizard just stops listening to the keyboard
	get_tree().paused = not Net.active
	if Net.active and world.player != null and world.player.brain != null:
		world.player.brain.enabled = false
		world.player.halt()
	menus.save_status.text = ""
	menus.refresh_pause()
	menus.show_only(menus.pause_panel)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func unpause() -> void:
	state = "playing"
	if hud != null:
		hud.visible = true
	get_tree().paused = false
	if world.player != null and world.player.brain != null:
		world.player.brain.enabled = true
	menus.hide_all()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func autosave() -> bool:
	if world == null or world.player == null or world.player_life == null or not world.player.alive:
		return false
	if state != "playing" and state != "paused":
		return false
	return Game.write_save(world.player_life.to_dict())


func _unstuck() -> void:
	var p := world.player
	if p == null:
		return
	var t := world.terrain
	var q := t.random_land_point(Vector2(p.position.x, p.position.z), 8.0, 0.3)
	p.position = Vector3(q.x, t.height(q.x, q.y), q.y)
	if p.rig.has_method("reset_chain"):
		p.rig.reset_chain()
	unpause()


# ------------------------------------------------------------------ multiplayer

## Open this world to other players. From the main menu this starts (or
## continues) a life; from the pause menu the current life simply carries on.
func host_game(continue_saved: bool, from_pause := false) -> void:
	_host_continue = continue_saved
	var port := int(Game.settings.get("net_port", Net.PORT))
	if Net.host(port, Game.player_name()) != OK:
		return
	if from_pause:
		get_tree().paused = false
		if world.player != null and world.player.brain != null:
			world.player.brain.enabled = false
			world.player.halt()
		menus.refresh_pause()


func join_game(address: String, port: int) -> void:
	Net.join(address, port, Game.player_name())


func _on_net_started() -> void:
	if Net.is_host:
		if world.player == null:
			if _host_continue and Game.has_save():
				continue_life()
			else:
				start_new_life()
		elif hud != null:
			hud.show_message("Your world is open. Others can join on port %d." % int(Game.settings.get("net_port", Net.PORT)))
		return
	# joined someone else's world
	_remove_player()
	world.enter_client_mode()
	if Game.has_save():
		continue_life()
		hud.show_message("You joined %s's world." % Net.player_name(1))
	else:
		start_new_life()
	if hud != null:
		hud.refresh_players()


func _on_net_ended(reason: String) -> void:
	var was_playing := state != "menu"
	if world.net_client:
		# keep this lizard for the next time we join (never over the single-player save)
		if world.player != null and world.player.alive and world.player_life != null and state != "hatching":
			Game.write_save(world.player_life.to_dict(), Game.NET_SAVE_PATH)
		_remove_player()
	world.exit_net_mode()
	if reason != "":
		menus.set_net_status(reason)
	if hud != null:
		hud.refresh_players()
	if was_playing and world.player == null:
		go_menu()
		if reason != "":
			menus.open_multiplayer()
