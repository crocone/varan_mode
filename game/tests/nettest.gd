extends Node
## Two-instance multiplayer test. Start one game with  -- --test=nethost
## and a second with  -- --test=netjoin  on the same machine.

const TEST_PORT := 24587

var main: Node
var world: World
var at: Node


func run(m: Node, harness: Node) -> void:
	main = m
	world = m.world
	at = harness
	if Game.test_mode == "nethost":
		await _host()
	else:
		await _join()


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec, true, false, true).timeout


func _avatar():
	for id in Net.players.keys():
		if id == 1:
			continue
		var av = Net.players[id].get("avatar")
		if av != null and is_instance_valid(av) and not av.removed:
			return av
	return null


func _next_to(me: Creature, other: Vector3, dist: float) -> void:
	var dir := Vector3(1, 0, 0.3).normalized()
	var p := other + dir * dist
	p.y = world.terrain.height(p.x, p.z)
	me.position = p
	var d := other - p
	me.yaw = atan2(d.x, d.z)
	me.rotation.y = me.yaw
	if me.rig.has_method("reset_chain"):
		me.rig.reset_chain()
	world.camera.yaw = me.yaw + PI + 0.6
	world.camera.pitch = -0.3


# ------------------------------------------------------------------ host

func _host() -> void:
	DisplayServer.window_set_position(Vector2i(0, 40))
	DisplayServer.window_set_size(Vector2i(960, 540))
	Game.settings.net_port = TEST_PORT
	Game.settings.player_name = "Hostling"
	main.host_game(false)
	await at._hatched()
	var p: Creature = world.player
	p.invulnerable = true
	print("NET host: hosting=", Net.is_host, " state=", main.state)
	var t := 0.0
	while Net.players.size() < 2 and t < 60.0:
		await _wait(0.5)
		t += 0.5
	print("NET host: players ", Net.players)
	var av = null
	for i in 80:
		av = _avatar()
		if av != null:
			break
		await _wait(0.25)
	if av == null:
		print("NET host FAIL: no avatar")
		return
	print("NET host: avatar id=%d mass=%.3f pos=%s name=%s" % [av.id, av.mass, av.position, av.net_name])
	var pvp_done := false
	var deaths_seen := 0
	var last_av = av
	for k in 70:
		await _wait(1.0)
		av = _avatar()
		if av != last_av and av != null:
			print("NET host: NEW avatar for the new life, id=%d mass=%.3f alive=%s" % [av.id, av.mass, av.alive])
			last_av = av
		if av != null and not av.alive and deaths_seen == 0:
			deaths_seen = 1
			print("NET host: avatar died, cause=%s  carcass meat=%.3f  in carcasses=%s" % [av.cause_of_death, av.meat, av in world.carcasses])
		if k % 4 == 0:
			print("NET host t=%d avatar=%s pos=%s act=%s speed=%.2f  snaps_out=%d kB_out=%.0f  hour=%.2f ts=%.1f" % [k,
				str(av.alive) if av != null else "none", str(av.position.snapped(Vector3.ONE * 0.01)) if av != null else "-",
				av.action if av != null else "-", av.speed if av != null else 0.0, Net.stats.snaps_out, Net.stats.bytes_out / 1024.0, world.hour, Engine.time_scale])
		if k == 14 and av != null:
			_next_to(p, av.position, 1.6)
			await _wait(0.6)
			await at._shot("net_host_view")
		if k == 24 and av != null and av.alive and not pvp_done:
			pvp_done = true
			p.set_mass(8.0)
			for b in 3:
				_next_to(p, av.position, p.length * 0.35 + 0.1)
				p.action = ""
				p.flinch = 0.0
				p.stamina = 1.0
				var ok := p.try_bite()
				await _wait(0.35)
				print("NET host: PvP bite %d started=%s  avatar alive=%s" % [b, ok, av.alive])
				await _wait(0.9)
			await at._shot("net_host_pvp")
		if Net.players.size() < 2 and k > 30:
			print("NET host: client left")
			break
	print("NET host: kill_log ", world.kill_log)
	print("NET host: done")


# ------------------------------------------------------------------ client

func _join() -> void:
	DisplayServer.window_set_position(Vector2i(960, 40))
	DisplayServer.window_set_size(Vector2i(960, 540))
	Game.delete_save(Game.NET_SAVE_PATH)
	Game.settings.player_name = "Guest"
	await _wait(2.0)
	main.join_game("127.0.0.1", TEST_PORT)
	var t := 0.0
	while main.state != "hatching" and main.state != "playing" and t < 30.0:
		await _wait(0.25)
		t += 0.25
	print("NET client: state=", main.state, " active=", Net.active, " client_mode=", world.net_client)
	if not Net.active:
		print("NET client FAIL: not connected")
		return
	await at._hatched()
	var p: Creature = world.player
	await _wait(1.0)
	_report("after hatch")
	await at._shot("net_client_start")
	# ---- hunt: the host must resolve our bites
	p.set_mass(0.6)
	var life: PlayerLife = world.player_life
	life.food = 30.0
	var kills0: int = life.stats.kills
	var victim: Creature = null
	for attempt in 10:
		var best: Creature = null
		var bd := 60.0
		for o in world.query(p.position, 60.0):
			var oc: Creature = o
			if oc.alive and oc.net_peer == 0 and oc.species_id in ["skink", "mouse", "frog", "grasshopper"]:
				var d := p.position.distance_to(oc.position)
				if d < bd:
					bd = d
					best = oc
		if best == null:
			await _wait(1.0)
			continue
		_next_to(p, best.position, p.length * 0.3 + 0.02)
		await _wait(0.45)
		p.action = ""
		p.stamina = 1.0
		p.try_bite()
		await _wait(1.2)
		print("NET client: bite attempt %d on %s(id %d) -> alive=%s kills=%d" % [attempt, best.species_id, best.id, best.alive, life.stats.kills])
		if life.stats.kills > kills0 or not best.alive:
			victim = best
			break
	# ---- eat the kill through the host
	if victim != null and is_instance_valid(victim) and not victim.removed:
		var f0 := life.food
		var s0 := life.stomach
		_next_to(p, victim.position, p.length * 0.3)
		await _wait(0.4)
		p.action = ""
		p.flinch = 0.0
		var ok := p.start_eat(victim)
		await _wait(3.0)
		print("NET client: eat started=%s  food %.1f -> %.1f  stomach %.4f -> %.4f  meals=%d  carcass removed=%s" % [ok, f0, life.food, s0, life.stomach, life.stats.eaten, not is_instance_valid(victim) or victim.removed])
	# ---- meet the host
	var hostp: Creature = null
	for i in 40:
		for c in world.puppets.values():
			if c.net_peer == 1:
				hostp = c
		if hostp != null and hostp.position.distance_to(p.position) < 6.0:
			break
		await _wait(0.5)
	if hostp != null:
		print("NET client: host puppet '%s' at %s dist %.1f" % [hostp.net_name, hostp.position.snapped(Vector3.ONE * 0.01), hostp.position.distance_to(p.position)])
		world.camera.yaw = atan2(p.position.x - hostp.position.x, p.position.z - hostp.position.z) + 0.4
		await _wait(0.5)
		await at._shot("net_client_meets_host")
	# ---- wait to be bitten by the (adult) host
	var h0 := p.health_frac()
	for i in 40:
		await _wait(0.5)
		if not p.alive:
			break
	print("NET client: health %.2f -> %.2f alive=%s cause=%s" % [h0, p.health_frac(), p.alive, p.cause_of_death])
	if not p.alive:
		await _wait(3.5)
		print("NET client: death panel visible=", main.menus.death_panel.visible)
		main.start_new_life()
		await at._hatched()
		print("NET client: new life mass=%.3f alive=%s my_life=%d" % [world.player.mass, world.player.alive, Net.my_life])
		await _wait(3.0)
		_report("after new life")
		await at._shot("net_client_newlife")
	await _wait(2.0)
	main.go_menu()
	await _wait(2.0)
	print("NET client: left; client_mode=%s creatures=%d puppets=%d" % [world.net_client, world.creatures.size(), world.puppets.size()])
	print("NET client: done")


func _report(tag: String) -> void:
	var sp := {}
	var avatars := []
	for c in world.puppets.values():
		sp[c.species_id] = sp.get(c.species_id, 0) + 1
		if c.net_peer != 0:
			avatars.append("%s(peer %d, %.2fkg, alive %s)" % [c.net_name, c.net_peer, c.mass, c.alive])
	print("NET client [%s]: puppets=%d avatars=%s species=%s snaps_in=%d hour=%.2f day=%d ts=%.1f" % [tag, world.puppets.size(), avatars, sp, Net.stats.snaps_in, world.hour, world.day, Engine.time_scale])
