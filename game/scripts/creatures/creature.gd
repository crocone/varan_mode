class_name Creature
extends Node3D
## One animal (player included). Handles locomotion on the heightfield,
## combat actions, damage, death and carcass state. Decisions come from
## `brain` (AI Brain or PlayerController); visuals from `rig`.

signal died(c: Creature, cause: String)

static var _next_id := 1

var id := 0
var species_id := ""
var sp: Dictionary
var world: Node
var terrain: Terrain
var brain = null
var rig: Node3D = null
var is_player := false
var sex := 0                 # 0 female, 1 male
var tag := ""

var mass := 1.0
var size := 1.0              # linear scale vs species reference
var length := 1.0
var radius := 0.1

var alive := true
var removed := false
var health := 1.0
var max_health := 1.0
var stamina := 1.0
var exhausted := false
var hunger := 0.3            # NPC hunger 0 (full) .. 1 (starving)
var thirst := 0.2

var yaw := 0.0
var speed := 0.0
var knock := Vector3.ZERO
var move_dir := Vector3.ZERO
var move_speed := 0.0
var sprinting := false
var stalking := false
var swimming := false
var flying := false
var fly_alt := 0.0
var climb_rate := 4.0
var blocked := false
var sheltered := false
var shelter_kind := ""
var cover := 0.0
var visibility := 1.0

var action := ""
var action_t := 0.0
var action_len := 0.0
var action_hit_done := false
var action_target: Creature = null
var eat_target = null        # Creature (carcass) or Dictionary (turkey mound)
var eat_tick := 0.0
var flinch := 0.0
var iframes := 0.0
var posturing := false
var posture_amt := 0.0
var resting := false
var rest_amt := 0.0
var courting := 0.0

var meat := 0.0
var decay := 0.0
var cause_of_death := ""
var killer_name := ""
var carried_by: Creature = null
var last_attacker: Creature = null
var last_hit_time := -99.0
var age_t := 0.0
var home := Vector3.ZERO
var territory := 0.0
var temp_factor := 1.0       # speed/regen multiplier (body temperature)
var speed_mult := 1.0        # external multiplier (old age, injury)
var dmg_mult := 1.0
var gait_phase := 0.0
var dist_travelled := 0.0
var hiss_t := 0.0
var lod := 0
var _stuck_t := 0.0
var climbing := false
var climb_tree: Dictionary = {}
var climb_h := 0.0
var climb_ang := 0.0
var climb_in := Vector2.ZERO    # x: around the trunk, y: up/down
var invulnerable := false       # test harness only
var part_skin: PartSkin = null
var _flies: AudioStreamPlayer3D = null

# multiplayer
var net_mode := 0               # 0 simulated here, 1 host-side mirror of a remote player, 2 client-side puppet
var net_peer := 0               # owning peer of a player lizard (0 = animal)
var net_flags := 0
var net_name := ""
var net_seen := 0
var hidden := false             # not drawn (e.g. still inside the egg)
var _net_buf: Array = []        # [time, pos, yaw, speed, climb_h, climb_ang]
var _net_label: Label3D = null
const NET_DELAY := 0.11


func setup(w: Node, species: String, m: float, pos: Vector3, yaw0 := -999.0) -> void:
	id = _next_id
	_next_id += 1
	world = w
	terrain = w.terrain
	species_id = species
	sp = Species.DEFS[species]
	sex = randi() % 2
	position = pos
	yaw = randf() * TAU if yaw0 < -100.0 else yaw0
	rotation.y = yaw
	home = pos
	set_mass(m)
	health = max_health
	hunger = randf_range(0.1, 0.5)
	thirst = randf_range(0.0, 0.4)
	_build_rig()


const RIG_SCRIPTS := {
	"reptile": "res://scripts/creatures/reptile_rig.gd",
	"mammal": "res://scripts/creatures/mammal_rig.gd",
	"bird": "res://scripts/creatures/bird_rig.gd",
}
static var _rig_cache := {}


func _build_rig() -> void:
	var path: String = RIG_SCRIPTS.get(sp.rig, "res://scripts/creatures/small_rig.gd")
	if not _rig_cache.has(path):
		var loaded = load(path) if ResourceLoader.exists(path) else null
		_rig_cache[path] = loaded if loaded != null and loaded.can_instantiate() else null
	var scr = _rig_cache[path]
	if scr != null:
		rig = scr.new()
	else:
		rig = _PlaceholderRig.new()
	add_child(rig)
	rig.setup(self)
	if sp.rig != "reptile":
		part_skin = PartSkin.try_attach(rig, species_id)
		if part_skin != null:
			part_skin.setup_fur(species_id)


## Fallback visual if a rig script is missing.
class _PlaceholderRig extends Node3D:
	var c
	func setup(cr) -> void:
		c = cr
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.5
		sm.height = 1.0
		mi.mesh = sm
		var pm := StandardMaterial3D.new()
		pm.albedo_color = Color(0.4, 0.33, 0.25)
		mi.material_override = pm
		mi.scale = Vector3(cr.length * 0.3, cr.length * 0.25, cr.length)
		mi.position.y = cr.length * 0.12
		add_child(mi)
	func update_rig(_dt: float) -> void:
		pass


func set_mass(m: float) -> void:
	var frac := health / max_health if max_health > 0.0 else 1.0
	mass = m
	size = pow(m / sp.ref_mass, 1.0 / 3.0)
	length = sp.length * size
	radius = maxf(0.01, length * sp.radius_k)
	max_health = 4.0 * pow(m, 0.65) * sp.hp
	health = clampf(frac, 0.0, 1.0) * max_health
	if rig != null and rig.has_method("on_resize"):
		rig.on_resize()
	if _net_label != null:
		_net_label.position.y = length * 0.14 + 0.28


# ------------------------------------------------------------ multiplayer

## A player-controlled lizard (the local player, a remote player's mirror or puppet).
func is_avatar() -> bool:
	return is_player or net_peer != 0


## Name used as a cause of death ("@Name" for other players).
func cause_name() -> String:
	if net_peer != 0 and net_name != "":
		return "@" + net_name
	if is_player and Net.active:
		return "@" + Net.my_name
	return sp.name


func set_net_name(n: String) -> void:
	net_name = n
	if _net_label == null:
		_net_label = Label3D.new()
		_net_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_net_label.fixed_size = true
		_net_label.pixel_size = 0.0008
		_net_label.font_size = 30
		_net_label.outline_size = 10
		_net_label.outline_modulate = Color(0.08, 0.05, 0.03, 0.85)
		_net_label.modulate = Color(1.0, 0.92, 0.72)
		_net_label.visibility_range_end = 90.0
		add_child(_net_label)
	_net_label.text = n
	_net_label.position.y = length * 0.14 + 0.28
	_net_label.visible = alive


func _net_push(p: Vector3, y: float, spd: float, ch: float, ca: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not _net_buf.is_empty():
		var last: Array = _net_buf.back()
		if (last[1] as Vector3).distance_to(p) > 6.0 + length * 2.0:
			_net_buf.clear()          # teleport: don't slide across the map
	if _net_buf.is_empty():
		position = p
		yaw = y
		rotation.y = y
	_net_buf.append([now, p, y, spd, ch, ca])
	while _net_buf.size() > 10:
		_net_buf.pop_front()


func _net_interp() -> void:
	if _net_buf.is_empty():
		return
	var t := Time.get_ticks_msec() / 1000.0 - NET_DELAY
	while _net_buf.size() >= 3 and _net_buf[1][0] <= t:
		_net_buf.pop_front()
	var a: Array = _net_buf[0]
	var p: Vector3 = a[1]
	var y: float = a[2]
	var spd: float = a[3]
	var ch: float = a[4]
	var ca: float = a[5]
	if _net_buf.size() >= 2 and t > a[0]:
		var b: Array = _net_buf[1]
		var f := clampf((t - a[0]) / maxf(b[0] - a[0], 0.001), 0.0, 1.0)
		p = a[1].lerp(b[1], f)
		y = lerp_angle(a[2], b[2], f)
		spd = lerpf(a[3], b[3], f)
		ch = lerpf(a[4], b[4], f)
		ca = lerp_angle(a[5], b[5], f)
	var moved := Vector2(p.x - position.x, p.z - position.z).length()
	if moved < 3.0:
		dist_travelled += moved
		gait_phase += moved / stride()
	position = p
	yaw = y
	rotation.y = y
	speed = spd
	climb_h = ch
	climb_ang = ca


func _default_action_len(a: String) -> float:
	match a:
		"bite":
			return 0.7 if species_id == "croc" else 0.42 + 0.12 * clampf(size, 0.0, 1.5)
		"whip":
			return 0.6
		"dodge":
			return 0.3
		"court":
			return 3.0
	return 1.0


func _net_set_climb(clim: bool, ti: int) -> void:
	if clim and ti >= 0 and ti < terrain.trees.size():
		if not climbing:
			climbing = true
			climb_tree = terrain.trees[ti]
	elif climbing:
		climbing = false
		climb_tree = {}
		if rig != null and rig.has_method("reset_chain"):
			rig.reset_chain()


## Client: a creature simulated on the host.
func apply_puppet(s: PackedFloat32Array) -> void:
	var flags := int(s[8])
	net_flags = flags
	flying = (flags & 2) != 0
	swimming = (flags & 4) != 0
	posturing = (flags & 8) != 0
	resting = (flags & 16) != 0
	sex = 1 if (flags & 8192) != 0 else 0
	if brain is NetBrain:
		brain.submerged = (flags & 4096) != 0
	if absf(s[7] - mass) > mass * 0.01:
		set_mass(s[7])
	health = clampf(s[9], 0.0, 1.0) * max_health
	var a: String = Net.ACTIONS[clampi(int(s[10]), 0, Net.ACTIONS.size() - 1)]
	if a != action:
		action = a
		action_t = s[11]
		action_len = _default_action_len(a)
		if (a == "bite" or a == "whip") and rig != null and rig.has_method("on_action"):
			rig.on_action(a)
	_net_set_climb((flags & 128) != 0, int(s[13]))
	_net_push(Vector3(s[2], s[3], s[4]), s[5], s[6], s[14], s[15])
	hidden = (flags & 16384) != 0
	if alive and (flags & 1) == 0:
		_net_buf.clear()
		position = Vector3(s[2], s[3], s[4])
		die("")
	meat = s[12]


## Host: the latest state of a remote player's lizard.
func apply_remote_state(s: PackedFloat32Array) -> void:
	var flags := int(s[8])
	net_flags = flags
	swimming = (flags & 4) != 0
	posturing = (flags & 8) != 0
	resting = (flags & 16) != 0
	stalking = (flags & 32) != 0
	sprinting = (flags & 64) != 0
	sheltered = (flags & 256) != 0
	sex = int(s[16])
	if absf(s[5] - mass) > mass * 0.005:
		set_mass(s[5])
	health = clampf(s[6] / maxf(s[7], 0.0001), 0.0, 1.0) * max_health
	visibility = clampf(s[11], 0.0, 1.0)
	cover = 1.0 if sheltered else clampf(1.0 - visibility, 0.0, 1.0)
	if action != "bite" and action != "whip":
		var a: String = Net.ACTIONS[clampi(int(s[9]), 0, Net.ACTIONS.size() - 1)]
		if a == "bite" or a == "whip":
			a = ""              # resolved here from the reliable action request
		if a != action:
			action = a
			action_t = s[10]
			action_len = _default_action_len(a)
	_net_set_climb((flags & 128) != 0, int(s[12]))
	_net_push(Vector3(s[0], s[1], s[2]), s[3], s[4], s[13], s[14])


func _net_tick(dt: float) -> void:
	_net_interp()
	knock = Vector3.ZERO
	if net_mode == 1 and (action == "bite" or action == "whip"):
		_update_action(dt)        # the host resolves the remote player's attacks
	elif action != "":
		action_t += dt
	flinch = maxf(0.0, flinch - dt)
	iframes = maxf(0.0, iframes - dt)
	hiss_t = maxf(0.0, hiss_t - dt)
	if posturing and alive and hiss_t <= 0.0 and species_id == "monitor":
		hiss_t = 1.6
		Sfx.play_at("hiss_big" if mass > 3.0 else "hiss", head_pos(), linear_to_db(clampf(0.35 + size, 0.35, 1.0)), clampf(1.6 - size * 0.6, 0.9, 1.6), 30.0)
	posture_amt = move_toward(posture_amt, 1.0 if posturing else 0.0, dt * 3.0)
	rest_amt = move_toward(rest_amt, 1.0 if resting else 0.0, dt * 1.5)
	if net_mode == 1:
		hidden = (net_flags & 16384) != 0


## Host: animate an attack the remote player started.
func play_remote_action(kind: String) -> void:
	action = kind
	action_t = 0.0
	action_len = _default_action_len(kind)
	action_hit_done = true           # hits come from the owner (see Net.c_hit)
	flinch = 0.0
	if rig != null and rig.has_method("on_action"):
		rig.on_action(kind)
	if kind == "whip":
		Sfx.play_at("tail_whip", position, linear_to_db(clampf(0.3 + size, 0.3, 1.0)), clampf(1.5 - size * 0.5, 0.8, 1.5), 30.0)


## Host: a hit the remote player landed on its own screen (already validated).
func apply_remote_hit(kind: String, oc: Creature) -> void:
	var dmg := bite_damage()
	if kind == "whip":
		dmg *= 0.45
		var to := oc.position - position
		to.y = 0
		oc.take_damage(dmg, self, "whip")
		if to.length_squared() > 0.0001:
			oc.knock += to.normalized() * clampf(mass / oc.mass, 0.3, 4.0) * 3.5
		oc.flinch = maxf(oc.flinch, 0.55)
		Sfx.play_at("bite_hit", oc.position, -6.0, 0.7, 30.0)
	else:
		oc.take_damage(dmg, self, "bite")
		Sfx.play_at("bite_hit", head_pos(), linear_to_db(clampf(0.4 + size * 0.8, 0.4, 1.0)), clampf(1.5 - size * 0.5, 0.8, 1.6), 35.0)
	if world.has_method("on_hit"):
		world.on_hit(self, oc, dmg)


## Host: the remote player reported its death.
func net_die(cause: String) -> void:
	var killer: Creature = null
	if last_attacker != null and is_instance_valid(last_attacker) and world.time - last_hit_time < 20.0:
		killer = last_attacker
	net_mode = 0
	_net_buf.clear()
	die(cause, killer)


## Client: the host resolved one of our eat / dig requests.
func on_remote_ate(amount: float, what: String) -> void:
	if amount <= 0.0:
		if action == "eat":
			action = ""
			eat_target = null
		return
	_ingest(amount, what)
	if what == "egg":
		Sfx.play_at("egg_crack", head_pos(), -2.0, 1.0, 20.0)
	else:
		Sfx.play_at("crunch", head_pos(), linear_to_db(clampf(0.35 + size, 0.35, 1.0)), clampf(1.5 - size * 0.5, 0.8, 1.5), 20.0)
	if is_player and world.player_life != null and world.player_life.is_full():
		action = ""
		eat_target = null


## Client: something on the host hurt our lizard.
func take_remote_damage(amount: float, attacker_name: String, apos: Vector3, amass: float, src: Creature) -> void:
	if not alive or iframes > 0.0 or invulnerable:
		return
	if is_player and world.player_life != null:
		amount = world.player_life.modify_damage(amount)
		if health > max_health * 0.35:
			amount = minf(amount, health - max_health * 0.1)
	health -= amount
	if src != null:
		last_attacker = src
	last_hit_time = world.time
	flinch = maxf(flinch, clampf(amount / max_health * 1.5, 0.12, 0.6))
	if action == "eat" or action == "drink" or action == "court":
		cancel_action()
	var away := position - apos
	away.y = 0
	if away.length_squared() > 0.0001:
		knock += away.normalized() * clampf(amass / mass, 0.2, 3.0) * 1.6
	if climbing and amount > max_health * 0.3:
		stop_climb(true)
	if rig != null and rig.has_method("on_hit"):
		rig.on_hit()
	var hs: String = sp.sounds.get("hurt", "")
	if hs != "":
		Sfx.play_at(hs, position, linear_to_db(clampf(0.4 + size * 0.8, 0.4, 1.0)), clampf(1.5 - size * 0.5, 0.8, 1.7), 40.0, 0.3)
	if health <= 0.0:
		health = 0.0
		die(attacker_name, src)


## Stand-in brain for puppets: carries the few fields the rigs read.
class NetBrain extends RefCounted:
	var state := ""
	var look_point = null
	var tongue_now := false
	var submerged := false
	var target = null
	func update(_dt: float) -> void:
		pass


# ------------------------------------------------------------ derived values

func health_frac() -> float:
	return clampf(health / max_health, 0.0, 1.0)


func fwd() -> Vector3:
	return Vector3(sin(yaw), 0.0, cos(yaw))


func head_pos() -> Vector3:
	var k: float = sp.get("head_k", 0.33 if sp.rig == "reptile" else 0.5)
	return position + fwd() * length * k + Vector3.UP * length * 0.06


func walk_speed() -> float:
	var s: float
	if species_id == "monitor":
		s = 0.7 + 1.5 * size
	else:
		s = sp.walk * pow(size, 0.3)
	return s * temp_factor * speed_mult


func run_speed() -> float:
	var s: float
	if species_id == "monitor":
		s = 1.8 + 3.8 * size
	else:
		s = sp.run * pow(size, 0.3)
	if exhausted:
		s = walk_speed() * 1.05
	return s * temp_factor * speed_mult


func stride() -> float:
	return maxf(0.02, length * (0.28 if sp.rig == "reptile" else 0.45))


func bite_damage() -> float:
	return pow(mass, 0.6) * sp.dmg * lerpf(0.6, 1.0, temp_factor) * dmg_mult


## How threatening this animal looks to another (used for posturing contests).
func intimidation() -> float:
	var v := mass * (0.55 + 0.45 * health_frac())
	if posturing:
		v *= 1.35
	return v


func can_hunt(o: Creature) -> bool:
	if not o.alive or o == self:
		return false
	if o.climbing and o.climb_h > maxf(0.8, length * 0.6):
		return false
	if o.species_id == species_id:
		return species_id == "monitor" and mass > 2.5 and o.mass < mass * 0.07
	var cat: String = o.sp.cat
	if not (cat in sp.eats):
		return false
	return o.mass <= mass * sp.prey_ratio


func is_busy() -> bool:
	return action != "" or flinch > 0.0


# ------------------------------------------------------------ control API

func steer(dir: Vector3, spd: float) -> void:
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		move_dir = Vector3.ZERO
		move_speed = 0.0
		return
	move_dir = dir.normalized()
	move_speed = spd


# ------------------------------------------------------------ climbing

func can_climb() -> bool:
	return species_id == "monitor" and mass < 6.0 and alive


func climb_top() -> float:
	return climb_tree.height * 0.5 if not climb_tree.is_empty() else 0.0


func start_climb(t: Dictionary) -> bool:
	if climbing or not can_climb() or t.is_empty():
		return false
	climbing = true
	climb_tree = t
	climb_h = length * 0.12
	var d: Vector2 = Vector2(position.x, position.z) - t.p
	climb_ang = atan2(d.y, d.x)
	action = ""
	resting = false
	speed = 0.0
	knock = Vector3.ZERO
	return true


func stop_climb(jump := false) -> void:
	if not climbing:
		return
	climbing = false
	var t := climb_tree
	var radial := Vector2(cos(climb_ang), sin(climb_ang))
	var p2: Vector2 = t.p + radial * (t.r0 + radius + length * 0.25)
	p2 = terrain.push_out(p2, radius, mass)
	position = Vector3(p2.x, terrain.height(p2.x, p2.y), p2.y)
	yaw = atan2(radial.x, radial.y)
	rotation.y = yaw
	if jump:
		knock = Vector3(radial.x, 0, radial.y) * run_speed()
	climb_tree = {}
	climb_h = 0.0
	if rig != null and rig.has_method("reset_chain"):
		rig.reset_chain()


func _climb_move(dt: float) -> void:
	var t := climb_tree
	var spd := walk_speed() * 0.55 * (1.5 if sprinting and not exhausted else 1.0)
	var R := Terrain.trunk_radius(t, climb_h)
	climb_h += climb_in.y * spd * dt
	climb_ang += climb_in.x * spd * dt / maxf(R + length * 0.05, 0.05)
	if climb_h <= 0.0 and climb_in.y < 0.0:
		stop_climb()
		return
	climb_h = clampf(climb_h, 0.0, climb_top())
	speed = spd * clampf(absf(climb_in.y) + absf(climb_in.x) * 0.6, 0.0, 1.0)
	if climb_in.y > 0.0:
		stamina = maxf(0.0, stamina - 0.02 * dt)
	var moved := speed * dt
	dist_travelled += moved
	gait_phase += moved / stride()
	R = Terrain.trunk_radius(t, climb_h)
	var radial := Vector3(cos(climb_ang), 0.0, sin(climb_ang))
	var base_y: float = terrain.hmap(t.p.x, t.p.y)
	position = Vector3(t.p.x, base_y + climb_h, t.p.y) + radial * (R + length * 0.03)
	yaw = atan2(-radial.x, -radial.z)
	rotation.y = yaw
	swimming = false


func halt() -> void:
	move_dir = Vector3.ZERO
	move_speed = 0.0


func face(pos: Vector3, dt: float, rate := -1.0) -> void:
	var d := pos - position
	if d.length_squared() < 0.0001:
		return
	var ty := atan2(d.x, d.z)
	var r: float = (sp.turn if rate < 0.0 else rate) * dt
	yaw += clampf(wrapf(ty - yaw, -PI, PI), -r, r)


# ------------------------------------------------------------ tick

func tick(dt: float) -> void:
	if removed:
		return
	age_t += dt
	if net_mode != 0:
		_net_tick(dt)
		return
	if not alive:
		_tick_dead(dt)
		return
	if brain != null:
		brain.update(dt)
	_update_action(dt)
	if climbing:
		_climb_move(dt)
	else:
		_move(dt)
	_update_status(dt)


func update_visual(dt: float) -> void:
	if rig != null and rig.visible:
		rig.update_rig(dt)
		if part_skin != null:
			part_skin.update()
			var cam := get_viewport().get_camera_3d()
			if cam != null:
				part_skin.update_fur(cam.global_position)


func _move(dt: float) -> void:
	var target_speed := move_speed
	if action == "eat" or action == "drink" or action == "court":
		target_speed = 0.0
	if resting:
		target_speed = 0.0
	if flinch > 0.0:
		target_speed *= 0.35
	if posturing:
		target_speed = minf(target_speed, walk_speed() * 0.45)
	if move_dir.length_squared() > 0.0001:
		var tyaw := atan2(move_dir.x, move_dir.z)
		var diff := wrapf(tyaw - yaw, -PI, PI)
		var tr: float = sp.turn * (1.6 if speed < walk_speed() * 0.5 else 1.0)
		if swimming:
			tr *= 0.7
		yaw += clampf(diff, -tr * dt, tr * dt)
		if not flying:
			target_speed *= clampf(cos(diff) * 1.3, 0.12, 1.0)
	else:
		target_speed = 0.0
	var acc: float = sp.accel
	if target_speed < speed:
		acc *= 1.6
	speed = move_toward(speed, target_speed, acc * dt)
	var f := fwd()
	var vel := f * speed + knock
	knock *= exp(-7.0 * dt)
	var old := position
	var np := position + vel * dt
	var p2 := Vector2(np.x, np.z)
	if not flying or position.y - terrain.height(p2.x, p2.y) < 2.0:
		p2 = terrain.push_out(p2, radius, mass)
	p2 = terrain.clamp_play(p2)
	blocked = false
	var depth := terrain.water_depth(p2.x, p2.y)
	if sp.get("fish", false):
		if depth < 0.3:
			p2 = Vector2(old.x, old.z)
			blocked = true
			speed *= 0.3
	elif not flying and not sp.get("swims", false) and depth > maxf(0.12, length * 0.25):
		# non-swimmers refuse to wade deeper
		var od := terrain.water_depth(old.x, old.z)
		if depth > od:
			p2 = Vector2(old.x, old.z)
			blocked = true
			speed *= 0.3
	var moved := Vector2(p2.x - old.x, p2.y - old.z).length()
	dist_travelled += moved
	gait_phase += moved / stride()
	var ground := terrain.height(p2.x, p2.y)
	depth = WATER - ground
	var swim_depth := maxf(0.06, length * 0.09)
	swimming = sp.get("swims", false) and depth > swim_depth and not flying
	var ny: float
	if flying:
		var tgt := ground + fly_alt
		if fly_alt > 0.5:
			tgt = maxf(tgt, WATER + fly_alt * 0.8)
		ny = move_toward(position.y, tgt, climb_rate * dt)
		ny = maxf(ny, ground)
	elif sp.get("fish", false):
		ny = WATER - clampf(depth * 0.45, 0.12, 1.2)
	elif swimming:
		ny = WATER - swim_depth * 0.7
	else:
		ny = ground
	position = Vector3(p2.x, ny, p2.y)
	rotation.y = yaw
	# stuck detection for AI
	if move_speed > 0.2 and moved < move_speed * dt * 0.15:
		_stuck_t += dt
	else:
		_stuck_t = maxf(0.0, _stuck_t - dt)
	if _stuck_t > 1.5:
		blocked = true
		_stuck_t = 0.0


const WATER := 0.0


func _update_status(dt: float) -> void:
	flinch = maxf(0.0, flinch - dt)
	iframes = maxf(0.0, iframes - dt)
	hiss_t = maxf(0.0, hiss_t - dt)
	# stamina
	var running := speed > walk_speed() * 1.15 and sprinting
	if running:
		stamina -= dt * (0.16 if is_player else sp.get("stamina_drain", 0.07))
		if stamina <= 0.0:
			stamina = 0.0
			exhausted = true
	else:
		var regen := 0.14 * temp_factor * (0.6 if speed > 0.1 else 1.0)
		if resting:
			regen *= 1.6
		stamina = minf(1.0, stamina + dt * regen)
		if exhausted and stamina > 0.35:
			exhausted = false
	if posturing:
		stamina = maxf(0.0, stamina - dt * 0.03)
		if hiss_t <= 0.0:
			hiss_t = 1.6
			var snd := "hiss_big" if mass > 3.0 else "hiss"
			if species_id == "monitor":
				Sfx.play_at(snd, head_pos(), linear_to_db(clampf(0.35 + size, 0.35, 1.0)), clampf(1.6 - size * 0.6, 0.9, 1.6), 30.0)
	posture_amt = move_toward(posture_amt, 1.0 if posturing else 0.0, dt * 3.0)
	rest_amt = move_toward(rest_amt, 1.0 if resting else 0.0, dt * 1.5)
	# NPC regen and needs
	if not is_player:
		if world.time - last_hit_time > 12.0:
			health = minf(max_health, health + max_health * 0.006 * dt)
		hunger = minf(1.0, hunger + dt / sp.get("hunger_time", 260.0))
		thirst = minf(1.0, thirst + dt / 420.0)
	# concealment (only matters for things that can be hunted)
	if lod == 0 or is_player:
		cover = terrain.cover(position.x, position.z, mass)
		var sh := terrain.shelter_at(position.x, position.z, mass) if not flying else {}
		sheltered = not sh.is_empty()
		shelter_kind = sh.get("kind", "")
	var vis := 1.0 - cover
	if stalking:
		vis *= 0.55
	if resting and cover > 0.3:
		vis *= 0.7
	if speed > walk_speed() * 1.2:
		vis = maxf(vis, 0.55)
	if climbing:
		var in_canopy: bool = climb_h > climb_tree.height * 0.3
		vis *= 0.35 if in_canopy else 0.6
		cover = maxf(cover, 0.85 if in_canopy else 0.4)
	if sheltered:
		vis = 0.0
	if swimming and species_id == "croc":
		vis *= 0.3
	visibility = vis


# ------------------------------------------------------------ actions

func try_bite() -> bool:
	if not alive or action != "" or flinch > 0.0 or carried_by != null:
		return false
	if stamina < 0.06 and is_player:
		return false
	action = "bite"
	action_t = 0.0
	action_len = 0.42 + 0.12 * clampf(size, 0.0, 1.5)
	if species_id == "croc":
		action_len = 0.7
	action_hit_done = false
	stamina = maxf(0.0, stamina - (0.09 if is_player else 0.04))
	action_target = _find_target(PI * 0.45, reach() * 2.6)
	if is_player and Net.is_client():
		Net.send_action("bite")
	if rig != null and rig.has_method("on_action"):
		rig.on_action("bite")
	var atk: String = sp.sounds.get("attack", "")
	if atk != "" and randf() < 0.35 and not is_player:
		Sfx.play_at(atk, head_pos(), -4.0, 1.0, 40.0, 1.0)
	return true


func try_whip() -> bool:
	if not alive or action != "" or flinch > 0.0 or sp.rig != "reptile":
		return false
	if stamina < 0.1 and is_player:
		return false
	action = "whip"
	action_t = 0.0
	action_len = 0.6
	action_hit_done = false
	stamina = maxf(0.0, stamina - (0.13 if is_player else 0.05))
	if is_player and Net.is_client():
		Net.send_action("whip")
	if rig != null and rig.has_method("on_action"):
		rig.on_action("whip")
	Sfx.play_at("tail_whip", position, linear_to_db(clampf(0.3 + size, 0.3, 1.0)), clampf(1.5 - size * 0.5, 0.8, 1.5), 30.0)
	return true


func try_dodge(dir: Vector3) -> bool:
	if not alive or action == "dodge" or stamina < 0.12 or carried_by != null:
		return false
	if action == "eat" or action == "drink" or action == "court":
		action = ""
	elif action != "":
		return false
	if dir.length_squared() < 0.01:
		dir = -fwd()
	dir.y = 0
	action = "dodge"
	action_t = 0.0
	action_len = 0.3
	iframes = 0.22
	stamina -= 0.14 if is_player else 0.05
	knock = dir.normalized() * run_speed() * 1.7
	Sfx.play_at("step_grass", position, -6.0, 1.3, 20.0)
	return true


func start_eat(target) -> bool:
	if not alive or action != "":
		return false
	action = "eat"
	action_t = 0.0
	eat_target = target
	eat_tick = 0.25
	return true


func start_drink() -> bool:
	if not alive or action != "":
		return false
	action = "drink"
	action_t = 0.0
	eat_tick = 0.6
	return true


func start_court(partner: Creature) -> bool:
	if action != "":
		return false
	action = "court"
	action_t = 0.0
	action_len = 3.0
	action_target = partner
	return true


func cancel_action() -> void:
	if action == "eat" or action == "drink" or action == "court":
		action = ""
		eat_target = null


func reach() -> float:
	return maxf(0.05, length * (0.22 if sp.rig == "reptile" else 0.3))


func _find_target(max_angle: float, max_d: float) -> Creature:
	var best: Creature = null
	var best_s := 1e9
	var hp := head_pos()
	for o in world.query(position, max_d + length):
		var oc: Creature = o
		if oc == self or not oc.alive or oc.carried_by != null:
			continue
		if brain != null and brain.has_method("is_friend") and brain.is_friend(oc):
			continue
		var d := oc.position - position
		d.y = 0
		var dist := hp.distance_to(oc.position) - oc.radius
		if dist > max_d:
			continue
		var ang := absf(wrapf(atan2(d.x, d.z) - yaw, -PI, PI))
		if ang > max_angle:
			continue
		var s := dist + ang * 1.5
		if s < best_s:
			best_s = s
			best = oc
	return best


func _update_action(dt: float) -> void:
	if action == "":
		return
	action_t += dt
	match action:
		"bite":
			var strike := action_len * 0.35
			if action_target != null and is_instance_valid(action_target) and action_target.alive and action_t < strike:
				face(action_target.position, dt, 14.0)
			if action_t > strike * 0.6 and action_t < strike * 1.4:
				knock += fwd() * run_speed() * 5.0 * dt
			if not action_hit_done and action_t >= strike:
				action_hit_done = true
				_resolve_bite()
			if action_t >= action_len:
				action = ""
		"whip":
			if not action_hit_done and action_t >= 0.25:
				action_hit_done = true
				_resolve_whip()
			if action_t >= action_len:
				action = ""
		"dodge":
			if action_t >= action_len:
				action = ""
		"eat":
			_update_eat(dt)
		"drink":
			eat_tick -= dt
			if eat_tick <= 0.0:
				eat_tick = 0.8
				Sfx.play_at("drink", head_pos(), linear_to_db(clampf(0.4 + size, 0.4, 1.0)), clampf(1.4 - size * 0.4, 0.9, 1.4), 18.0)
				thirst = maxf(0.0, thirst - 0.2)
				if is_player and world.player_life != null:
					world.player_life.on_drink(0.8)
					if world.player_life.water >= 99.9:
						action = ""
				elif thirst <= 0.0:
					action = ""
		"court":
			if action_target != null and is_instance_valid(action_target):
				face(action_target.position, dt, 3.0)
			if action_t >= action_len:
				action = ""
				if is_player and world.player_life != null:
					world.player_life.on_courted(action_target)


func _resolve_bite() -> void:
	var hp := head_pos()
	var victim: Creature = null
	var best := 1e9
	var r := reach()
	var intended = null
	var free_aim := is_avatar()
	if not free_aim and brain != null:
		intended = brain.get("target")
		if action_target != null and is_instance_valid(action_target):
			intended = action_target
	for o in world.query(hp, r + 3.0):
		var oc: Creature = o
		if oc == self or not oc.alive or oc.carried_by != null:
			continue
		if not free_aim and oc != intended:
			continue
		if oc.flying and oc.position.y - position.y > length * 0.8 + 0.3:
			continue
		var d := hp - oc.position
		d.y *= 0.5
		var dist := d.length() - oc.radius - oc.length * 0.25
		if dist > r:
			continue
		var to := oc.position - position
		var ang := absf(wrapf(atan2(to.x, to.z) - yaw, -PI, PI))
		if ang > PI * 0.55 and dist > r * 0.3:
			continue
		if dist < best:
			best = dist
			victim = oc
	if victim != null:
		var dmg := bite_damage()
		if is_player and Net.is_client():
			Net.send_hit("bite", victim)             # the host validates and applies it
		else:
			victim.take_damage(dmg, self, "bite")
		Sfx.play_at("bite_hit", hp, linear_to_db(clampf(0.4 + size * 0.8, 0.4, 1.0)), clampf(1.5 - size * 0.5, 0.8, 1.6), 35.0)
		if world.has_method("on_hit"):
			world.on_hit(self, victim, dmg)
	else:
		Sfx.play_at("bite_snap", hp, linear_to_db(clampf(0.3 + size * 0.7, 0.3, 0.9)), clampf(1.6 - size * 0.6, 0.8, 1.7), 25.0)


func _resolve_whip() -> void:
	var r := length * 0.75
	for o in world.query(position, r + 2.0):
		var oc: Creature = o
		if oc == self or not oc.alive:
			continue
		var to := oc.position - position
		to.y = 0
		var dist := to.length() - oc.radius
		if dist > r:
			continue
		var ang := absf(wrapf(atan2(to.x, to.z) - yaw, -PI, PI))
		if ang < PI * 0.3 and dist > length * 0.2:
			continue
		var dmg := bite_damage() * 0.45
		if is_player and Net.is_client():
			Net.send_hit("whip", oc)
			Sfx.play_at("bite_hit", oc.position, -6.0, 0.7, 30.0)
			continue
		oc.take_damage(dmg, self, "whip")
		oc.knock += to.normalized() * clampf(mass / oc.mass, 0.3, 4.0) * 3.5
		oc.flinch = maxf(oc.flinch, 0.55)
		oc.action = "" if oc.action == "bite" and not oc.action_hit_done else oc.action
		Sfx.play_at("bite_hit", oc.position, -6.0, 0.7, 30.0)
		if world.has_method("on_hit"):
			world.on_hit(self, oc, dmg)


func _update_eat(dt: float) -> void:
	eat_tick -= dt
	if eat_tick > 0.0:
		return
	eat_tick = 0.85
	var bite_size := maxf(mass * 0.05, 0.004)
	if typeof(eat_target) == TYPE_OBJECT and not is_instance_valid(eat_target):
		action = ""
		eat_target = null
		return
	if eat_target is Creature:
		var carcass: Creature = eat_target
		if not is_instance_valid(carcass) or carcass.removed or carcass.meat <= 0.0 or carcass.carried_by != null:
			action = ""
			eat_target = null
			return
		if head_pos().distance_to(carcass.position) > reach() + carcass.length * 0.6 + 0.4:
			action = ""
			eat_target = null
			return
		if is_player and Net.is_client():
			Net.request_eat(carcass, bite_size)
			return
		var amount := minf(carcass.meat, bite_size)
		var whole := carcass.meat <= bite_size * 1.3
		if whole:
			amount = carcass.meat
		carcass.meat -= amount
		_ingest(amount, carcass.species_id)
		if whole or carcass.meat <= 0.001:
			Sfx.play_at("gulp", head_pos(), linear_to_db(clampf(0.4 + size, 0.4, 1.0)), clampf(1.5 - size * 0.5, 0.8, 1.5), 20.0)
			carcass.meat = 0.0
			world.remove_creature(carcass)
			action = ""
			eat_target = null
		else:
			Sfx.play_at("crunch", head_pos(), linear_to_db(clampf(0.35 + size, 0.35, 1.0)), clampf(1.5 - size * 0.5, 0.8, 1.5), 20.0)
	elif eat_target is Dictionary:
		var m: Dictionary = eat_target
		if m.get("eggs", 0) <= 0:
			action = ""
			eat_target = null
			return
		if is_player and Net.is_client():
			Net.request_dig(terrain.turkey_mounds.find(m))
			action = ""
			eat_target = null
			return
		m.eggs -= 1
		Sfx.play_at("egg_crack", head_pos(), -2.0, 1.0, 20.0)
		_ingest(0.12, "egg")
		action = ""
		eat_target = null
	if is_player and world.player_life != null and world.player_life.is_full():
		action = ""
		eat_target = null


func _ingest(amount: float, what: String) -> void:
	if is_player and world.player_life != null:
		world.player_life.on_eat(amount, what)
	else:
		hunger = maxf(0.0, hunger - amount / maxf(mass * 0.12, 0.0005))


# ------------------------------------------------------------ damage & death

func take_damage(amount: float, attacker: Creature, kind := "bite") -> void:
	if not alive or iframes > 0.0 or invulnerable or net_mode == 2:
		return
	if net_mode == 1:
		# a remote player's lizard: its owner applies the damage and reports back
		if attacker != null:
			last_attacker = attacker
		last_hit_time = world.time
		flinch = maxf(flinch, clampf(amount / max_health * 1.5, 0.12, 0.6))
		if rig != null and rig.has_method("on_hit"):
			rig.on_hit()
		var hs0: String = sp.sounds.get("hurt", "")
		if hs0 != "":
			Sfx.play_at(hs0, position, linear_to_db(clampf(0.4 + size * 0.8, 0.4, 1.0)), clampf(1.5 - size * 0.5, 0.8, 1.7), 40.0, 0.3)
		Net.send_damage(net_peer, amount, attacker, kind)
		return
	if is_player and world.player_life != null:
		amount = world.player_life.modify_damage(amount)
		if health > max_health * 0.35:
			amount = minf(amount, health - max_health * 0.1)
	health -= amount
	if attacker != null:
		last_attacker = attacker
	last_hit_time = world.time
	flinch = maxf(flinch, clampf(amount / max_health * 1.5, 0.12, 0.6))
	if action == "eat" or action == "drink" or action == "court":
		cancel_action()
	if attacker != null:
		var away := position - attacker.position
		away.y = 0
		if away.length_squared() > 0.0001:
			knock += away.normalized() * clampf(attacker.mass / mass, 0.2, 3.0) * 1.6
	if climbing and amount > max_health * 0.3:
		stop_climb(true)
	if rig != null and rig.has_method("on_hit"):
		rig.on_hit()
	var hs: String = sp.sounds.get("hurt", "")
	if hs != "":
		Sfx.play_at(hs, position, linear_to_db(clampf(0.4 + size * 0.8, 0.4, 1.0)), clampf(1.5 - size * 0.5, 0.8, 1.7), 40.0, 0.3)
	if brain != null and brain.has_method("on_damaged"):
		brain.on_damaged(attacker, amount)
	if health <= 0.0:
		health = 0.0
		var cause := kind
		if attacker != null:
			cause = attacker.cause_name()
		die(cause, attacker)


func die(cause: String, killer: Creature = null) -> void:
	if not alive:
		return
	if climbing:
		stop_climb()
	alive = false
	action = ""
	speed = 0.0
	posturing = false
	resting = false
	move_speed = 0.0
	flying = false
	meat = mass * 0.6
	decay = 0.0
	cause_of_death = cause
	killer_name = killer.sp.name if killer != null else ""
	if _net_label != null:
		_net_label.visible = false
	if rig != null and rig.has_method("on_death"):
		rig.on_death()
	# drop to the ground
	position.y = terrain.height(position.x, position.z) if not sp.get("fish", false) else maxf(terrain.height(position.x, position.z), WATER - 0.1)
	if mass > 1.0 and not is_avatar():
		_flies = AudioStreamPlayer3D.new()
		_flies.stream = Sfx.streams.get("carcass_flies")
		_flies.bus = "SFX"
		_flies.volume_db = -14.0
		_flies.max_distance = 18.0
		_flies.unit_size = 2.0
		add_child(_flies)
	died.emit(self, cause)
	if world.has_method("on_death"):
		world.on_death(self, killer)


func _tick_dead(dt: float) -> void:
	decay += dt
	if carried_by != null:
		if not is_instance_valid(carried_by) or not carried_by.alive:
			carried_by = null
		else:
			position = carried_by.position + Vector3(0, -carried_by.length * 0.25, 0)
			return
	if _flies != null and decay > 20.0 and not _flies.playing and _flies.stream != null:
		_flies.play()
	meat -= dt * mass * 0.0004
	if meat <= 0.0 or decay > 520.0:
		world.remove_creature(self)
