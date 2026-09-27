extends Node
## Multiplayer: host-authoritative shared ecosystem over ENet.
##
## * The host runs the whole world (AI, spawning, day cycle) and streams
##   snapshots of nearby creatures to each client (interest-managed).
## * Every player simulates their own lizard locally (no input lag) and sends
##   its state to the host; the host mirrors it as a "remote avatar" that NPCs
##   perceive, hunt and fight like any monitor.
## * Authority-sensitive interactions (bites, eating carcasses, digging eggs,
##   laying nests) are requests resolved by the host.

signal status(text: String)
signal session_started
signal session_ended(reason: String)
signal players_changed

const PORT := 24580
const MAX_PLAYERS := 8
const SNAP_HZ := 15.0
const STATE_HZ := 20.0
const INTEREST := 140.0
const ACTIONS := ["", "bite", "whip", "dodge", "eat", "drink", "court"]
const STRIDE := 17
const CHUNK := 17                # creatures per snapshot packet (keeps packets under the ENet MTU)

var active := false
var is_host := false
var my_name := "Varan"
var my_life := 0                 # increments with every new life (lets the host tell lives apart)
var players := {}                # peer_id -> {name, slot, avatar (host side Creature), life}
var species_list: Array = []
var stats := {"snaps_in": 0, "snaps_out": 0, "bytes_out": 0}
var _snap_t := 0.0
var _state_t := 0.0
var _peer: ENetMultiplayerPeer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	species_list = Species.DEFS.keys()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func is_client() -> bool:
	return active and not is_host


func my_id() -> int:
	return multiplayer.get_unique_id() if active else 1


# ------------------------------------------------------------------ session

func host(port: int, player_name: String) -> Error:
	leave()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		_peer = null
		status.emit("Could not host on port %d (error %d). Is another game already hosting?" % [port, err])
		return err
	multiplayer.multiplayer_peer = _peer
	active = true
	is_host = true
	my_name = player_name
	players = {1: {"name": player_name, "slot": 1, "avatar": null, "life": -1}}
	status.emit("Hosting on UDP port %d. Others can join your IP address." % port)
	players_changed.emit()
	session_started.emit()
	return OK


func join(address: String, port: int, player_name: String) -> Error:
	leave()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port)
	if err != OK:
		_peer = null
		status.emit("Could not connect (error %d)." % err)
		return err
	multiplayer.multiplayer_peer = _peer
	is_host = false
	my_name = player_name
	status.emit("Connecting to %s:%d ..." % [address, port])
	return OK


func leave(reason := "") -> void:
	var was := active
	if _peer != null:
		_peer.close()
	multiplayer.multiplayer_peer = null
	_peer = null
	active = false
	is_host = false
	players.clear()
	Engine.time_scale = 1.0
	if was:
		session_ended.emit(reason)


func _on_connected() -> void:
	rpc_id(1, "c_hello", my_name, Game.VERSION)


func _on_connection_failed() -> void:
	status.emit("Connection failed. Check the address and that the host is running.")
	leave("Connection failed.")


func _on_server_disconnected() -> void:
	status.emit("The host closed the game.")
	leave("The host closed the game.")


func _on_peer_connected(_id: int) -> void:
	pass


func _on_peer_disconnected(id: int) -> void:
	if not is_host:
		return
	var p: Dictionary = players.get(id, {})
	var av = p.get("avatar")
	if av != null and is_instance_valid(av) and not av.removed:
		if av.alive:
			Game.world.remove_creature(av)
		else:
			av.net_peer = 0
	players.erase(id)
	_broadcast_players()
	_notify("%s left." % p.get("name", "A player"))


# ------------------------------------------------------------------ handshake

@rpc("any_peer", "reliable")
func c_hello(player_name: String, version: String) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if version != Game.VERSION:
		rpc_id(id, "s_reject", "Version mismatch (host %s, you %s)." % [Game.VERSION, version])
		return
	var nm := player_name.strip_edges().substr(0, 20)
	if nm == "":
		nm = "Varan %d" % (players.size() + 1)
	var slot := 2
	var used := {}
	for pid in players.keys():
		used[players[pid].slot] = true
	while used.has(slot):
		slot += 1
	players[id] = {"name": nm, "slot": slot, "avatar": null, "life": -1}
	var w = Game.world
	rpc_id(id, "s_welcome", w.hour, w.day)
	_broadcast_players()
	_notify("%s joined." % nm)


@rpc("authority", "reliable")
func s_reject(reason: String) -> void:
	status.emit(reason)
	leave(reason)


@rpc("authority", "reliable")
func s_welcome(hour: float, day: int) -> void:
	active = true
	is_host = false
	var w = Game.world
	w.hour = hour
	w.day = day
	status.emit("Connected.")
	session_started.emit()


func _broadcast_players() -> void:
	var list := {}
	for id in players.keys():
		list[id] = [players[id].name, players[id].slot]
	rpc("s_players", list)
	players_changed.emit()
	_refresh_names()


@rpc("authority", "reliable")
func s_players(list: Dictionary) -> void:
	players.clear()
	for id in list.keys():
		var e: Array = list[id]
		players[int(id)] = {"name": e[0], "slot": int(e[1]), "avatar": null, "life": -1}
	players_changed.emit()
	_refresh_names()


func _refresh_names() -> void:
	if Game.world != null and Game.world.has_method("refresh_net_names"):
		Game.world.refresh_net_names()


func _notify(text: String) -> void:
	_show(text)
	rpc("s_message", text)


func _show(text: String) -> void:
	if Game.main != null and Game.main.hud != null:
		Game.main.hud.show_message(text)


@rpc("authority", "reliable")
func s_message(text: String) -> void:
	_show(text)


func player_name(id: int) -> String:
	return players.get(id, {}).get("name", "Varan")


## Snapshots name owners by small slot numbers (peer ids don't survive float32).
func slot_of(peer: int) -> int:
	return int(players.get(peer, {}).get("slot", 0))


func slot_peer(slot: int) -> int:
	for id in players.keys():
		if players[id].slot == slot:
			return id
	return -slot


func my_slot() -> int:
	return slot_of(my_id())


# ------------------------------------------------------------------ per-frame

func _process(delta: float) -> void:
	if not active or Game.world == null:
		return
	var dt := delta / maxf(Engine.time_scale, 0.001)
	if is_host:
		_snap_t -= dt
		if _snap_t <= 0.0:
			_snap_t = 1.0 / SNAP_HZ
			_send_snapshots()
	else:
		_state_t -= dt
		if _state_t <= 0.0:
			_state_t = 1.0 / STATE_HZ
			_send_state()


# ------------------------------------------------------------------ client -> host: avatar state

func pack_state(c: Creature) -> PackedFloat32Array:
	var flags := 0
	if c.alive: flags |= 1
	if c.swimming: flags |= 4
	if c.posturing: flags |= 8
	if c.resting: flags |= 16
	if c.stalking: flags |= 32
	if c.sprinting: flags |= 64
	if c.climbing: flags |= 128
	if c.sheltered: flags |= 256
	var life = Game.world.player_life
	if life != null and life.sleeping: flags |= 2048
	if c.hidden: flags |= 16384
	var ti := -1
	if c.climbing:
		ti = Game.world.terrain.trees.find(c.climb_tree)
	return PackedFloat32Array([c.position.x, c.position.y, c.position.z, c.yaw, c.speed, c.mass, c.health, c.max_health,
		flags, maxi(0, ACTIONS.find(c.action)), c.action_t, c.visibility, ti, c.climb_h, c.climb_ang, my_life, c.sex])


func _send_state() -> void:
	var p = Game.world.player
	if p == null or p.removed or not p.alive:
		return
	rpc_id(1, "c_state", pack_state(p))


@rpc("any_peer", "unreliable_ordered")
func c_state(s: PackedFloat32Array) -> void:
	if not is_host or s.size() < STRIDE:
		return
	var id := multiplayer.get_remote_sender_id()
	if not players.has(id):
		return
	var w = Game.world
	var pl: Dictionary = players[id]
	var av = pl.avatar
	var life := int(s[15])
	var valid: bool = av != null and is_instance_valid(av) and not av.removed
	if valid and pl.life == life:
		if av.alive and av.net_mode == 1:
			av.apply_remote_state(s)
		return
	if (int(s[8]) & 1) == 0:
		return
	# a new life for this player: retire the old body
	if valid:
		if av.alive:
			w.remove_creature(av)
		else:
			av.net_peer = 0
	av = w.spawn_remote_avatar(id, s)
	pl.avatar = av
	pl.life = life
	av.apply_remote_state(s)


# ------------------------------------------------------------------ requests

func send_action(kind: String) -> void:
	if is_client():
		rpc_id(1, "c_action", kind)


## The remote lizard starts an attack: animation only - hits arrive via c_hit.
@rpc("any_peer", "reliable")
func c_action(kind: String) -> void:
	var av = _sender_avatar()
	if av != null and kind in ["bite", "whip"]:
		av.play_remote_action(kind)


## Client-side hit detection, validated here: the attacker saw the hit on its
## screen, so as long as the target was plausibly in reach it lands.
func send_hit(kind: String, target: Creature) -> void:
	if is_client() and target != null:
		rpc_id(1, "c_hit", kind, target.id)


@rpc("any_peer", "reliable")
func c_hit(kind: String, target_id: int) -> void:
	if not is_host:
		return
	var av = _sender_avatar()
	var w = Game.world
	var t = w.find_creature(target_id)
	if av == null or t == null or not t.alive or t == av or t.carried_by != null:
		return
	# generous tolerance for latency: ~0.3 s of movement for both animals
	var slack: float = 0.6 + (av.run_speed() + t.run_speed()) * 0.3
	var d: float = av.head_pos().distance_to(t.position) - t.radius - t.length * 0.3
	if kind == "whip":
		d = av.position.distance_to(t.position) - t.radius - av.length * 0.75
	if d > av.reach() + slack:
		return
	av.apply_remote_hit(kind, t)


func request_eat(target: Creature, bite: float) -> void:
	rpc_id(1, "c_eat", target.id, bite)


@rpc("any_peer", "reliable")
func c_eat(target_id: int, bite: float) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	var w = Game.world
	var carc = w.find_creature(target_id)
	var amount := 0.0
	var what := ""
	if carc != null and not carc.alive and carc.meat > 0.0 and carc.carried_by == null:
		bite = clampf(bite, 0.0, 1.0)
		amount = minf(carc.meat, bite)
		if carc.meat <= bite * 1.3:
			amount = carc.meat
		carc.meat -= amount
		what = carc.species_id
		if carc.meat <= 0.001:
			carc.meat = 0.0
			w.remove_creature(carc)
	rpc_id(id, "s_ate", amount, what)


func request_dig(mound_index: int) -> void:
	rpc_id(1, "c_dig", mound_index)


@rpc("any_peer", "reliable")
func c_dig(mound_index: int) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	var w = Game.world
	var amount := 0.0
	if mound_index >= 0 and mound_index < w.terrain.turkey_mounds.size():
		var m: Dictionary = w.terrain.turkey_mounds[mound_index]
		if m.eggs > 0:
			m.eggs -= 1
			amount = 0.12
	rpc_id(id, "s_ate", amount, "egg")


@rpc("authority", "reliable")
func s_ate(amount: float, what: String) -> void:
	var p = Game.world.player
	if p == null or not p.alive:
		return
	p.on_remote_ate(amount, what)


func request_nest(pos: Vector3, eggs: int, lineage: int) -> void:
	if is_client():
		rpc_id(1, "c_nest", pos, eggs, lineage)
	else:
		Game.world.add_nest(pos, eggs, lineage)


@rpc("any_peer", "reliable")
func c_nest(pos: Vector3, eggs: int, lineage: int) -> void:
	if is_host:
		Game.world.add_nest(pos, clampi(eggs, 1, 12), lineage)


## The client's lizard died (cause decided on the client, which owns its health).
func notify_died(cause: String) -> void:
	if is_client():
		rpc_id(1, "c_died", cause)


@rpc("any_peer", "reliable")
func c_died(cause: String) -> void:
	if not is_host:
		return
	var av = _sender_avatar()
	if av != null:
		av.net_die(cause)
		_notify("%s died (%s)." % [player_name(multiplayer.get_remote_sender_id()), _cause_text(cause)])


func _cause_text(cause: String) -> String:
	if cause.begins_with("@"):
		return "killed by " + cause.substr(1)
	match cause:
		"Old age", "Starvation", "Thirst", "Heatstroke":
			return cause.to_lower()
	return "killed by a " + cause.to_lower()


func _sender_avatar():
	var id := multiplayer.get_remote_sender_id()
	var pl: Dictionary = players.get(id, {})
	var av = pl.get("avatar")
	if av == null or not is_instance_valid(av) or av.removed or not av.alive:
		return null
	return av


# ------------------------------------------------------------------ host -> owner: damage & events

func send_damage(peer: int, amount: float, attacker: Creature, kind: String) -> void:
	if peer <= 1 or not is_host:
		return
	var nm := attacker.cause_name() if attacker != null else kind
	var apos := attacker.position if attacker != null else Vector3.ZERO
	var amass := attacker.mass if attacker != null else 1.0
	rpc_id(peer, "s_damage", amount, nm, apos, amass, attacker.id if attacker != null else -1)


@rpc("authority", "reliable")
func s_damage(amount: float, attacker_name: String, apos: Vector3, amass: float, attacker_id: int) -> void:
	var p = Game.world.player
	if p == null or not p.alive:
		return
	var src = Game.world.find_creature(attacker_id)
	p.take_remote_damage(amount, attacker_name, apos, amass, src)


## Things that happened to a remote player's avatar on the host that its
## PlayerLife wants to know about (kills, rivals backing down).
func send_event(peer: int, kind: String, sval := "", fval := 0.0, ival := 0) -> void:
	if peer <= 1 or not is_host:
		return
	rpc_id(peer, "s_event", kind, sval, fval, ival)


@rpc("authority", "reliable")
func s_event(kind: String, sval: String, fval: float, ival: int) -> void:
	var life = Game.world.player_life
	if life == null:
		return
	life.on_net_event(kind, sval, fval, ival)


# ------------------------------------------------------------------ host -> clients: snapshots

func _send_snapshots() -> void:
	var w = Game.world
	var mounds := PackedByteArray()
	for m in w.terrain.turkey_mounds:
		mounds.append(clampi(int(m.eggs), 0, 255))
	var nests := PackedFloat32Array()
	for n in w.nests:
		nests.append_array([n.p.x, n.p.y, n.p.z, n.eggs])
	var ts := _desired_time_scale()
	var header := PackedFloat32Array([w.time, w.hour, w.day, ts])
	for id in players.keys():
		if id == 1:
			continue
		var pl: Dictionary = players[id]
		var focus := Vector3.ZERO
		var av = pl.avatar
		if av != null and is_instance_valid(av) and not av.removed:
			focus = av.position
		else:
			focus = w.camera.global_position
		var data := PackedFloat32Array()
		var count := 0
		var part := 0
		for c in w.creatures:
			var cc: Creature = c
			if cc.removed:
				continue
			# small animals are only drawn close to the camera; don't send them from afar
			var d2 := Vector2(cc.position.x - focus.x, cc.position.z - focus.z).length_squared()
			if d2 > INTEREST * INTEREST:
				continue
			if cc.mass < 0.05 and d2 > 45.0 * 45.0:
				continue
			if cc.mass < 1.0 and d2 > 80.0 * 80.0 and not cc.flying:
				continue
			data.append_array(_pack_creature(cc))
			count += 1
			if count >= CHUNK:
				_send_chunk(id, header, data, mounds, nests, part)
				data = PackedFloat32Array()
				count = 0
				part += 1
		_send_chunk(id, header, data, mounds, nests, part)
		stats.snaps_out += 1
	Engine.time_scale = ts


func _send_chunk(id: int, header: PackedFloat32Array, data: PackedFloat32Array, mounds: PackedByteArray, nests: PackedFloat32Array, part: int) -> void:
	if part > 0 and data.is_empty():
		return
	# world state (clock, eggs, nests) rides on the first packet only
	var m := mounds if part == 0 else PackedByteArray()
	var n := nests if part == 0 else PackedFloat32Array()
	var h := header if part == 0 else PackedFloat32Array()
	rpc_id(id, "s_snap", h, data, m, n)
	stats.bytes_out += data.size() * 4 + h.size() * 4 + m.size() + n.size() * 4 + 24


func _desired_time_scale() -> float:
	# the world only fast-forwards when every living player is asleep
	var w = Game.world
	var all_asleep := true
	var any := false
	if w.player != null and w.player.alive:
		any = true
		if w.player_life == null or not w.player_life.sleeping:
			all_asleep = false
	for id in players.keys():
		if id == 1:
			continue
		var av = players[id].avatar
		if av == null or not is_instance_valid(av) or av.removed or not av.alive:
			continue
		any = true
		if (av.net_flags & 2048) == 0:
			all_asleep = false
	return 7.0 if any and all_asleep else 1.0


func _pack_creature(c: Creature) -> PackedFloat32Array:
	var flags := 0
	if c.alive: flags |= 1
	if c.flying: flags |= 2
	if c.swimming: flags |= 4
	if c.posturing: flags |= 8
	if c.resting: flags |= 16
	if c.climbing: flags |= 128
	if c.carried_by != null: flags |= 512
	if c.net_peer != 0 or c.is_player: flags |= 1024
	if c.brain != null and c.brain.get("submerged") == true: flags |= 4096
	if c.sex == 1: flags |= 8192
	if c.hidden: flags |= 16384
	var ti := -1
	if c.climbing:
		ti = Game.world.terrain.trees.find(c.climb_tree)
	var owner := slot_of(c.net_peer) if c.net_peer != 0 else (1 if c.is_player else 0)
	return PackedFloat32Array([c.id, species_list.find(c.species_id), c.position.x, c.position.y, c.position.z, c.yaw,
		c.speed, c.mass, flags, c.health_frac(), maxi(0, ACTIONS.find(c.action)), c.action_t, c.meat, ti, c.climb_h, c.climb_ang, owner])


@rpc("authority", "unreliable_ordered")
func s_snap(header: PackedFloat32Array, data: PackedFloat32Array, mounds: PackedByteArray, nests: PackedFloat32Array) -> void:
	if is_host or not active or Game.world == null:
		return
	var w = Game.world
	if header.size() >= 4:
		stats.snaps_in += 1
		w.hour = header[1]
		w.day = int(header[2])
		Engine.time_scale = header[3]
		for i in mounds.size():
			if i < w.terrain.turkey_mounds.size():
				w.terrain.turkey_mounds[i].eggs = mounds[i]
		w.net_sync_nests(nests)
	w.apply_snapshot(data, my_slot())
