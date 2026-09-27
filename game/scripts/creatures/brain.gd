class_name Brain
extends RefCounted
## Utility-flavoured state machine shared by every NPC species. Species
## differences come from the Species profile plus a few special behaviours
## (raptor dives, crocodile ambush, fish schooling, monitor territoriality).

var c: Creature
var w: Node
var state := "wander"
var state_t := 0.0
var think_t := 0.0
var target: Creature = null        # prey / opponent / carcass
var goal := Vector3.ZERO
var has_goal := false
var pause_t := 0.0
var threat: Creature = null
var flee_t := 0.0
var look_point = null
var tongue_now := false
var submerged := false
var mound: Dictionary = {}
var leader: Creature = null
var memory := {}                   # creature id -> fear (decays)
var posture_limit := 0.0
var rival_start_d := 0.0
var avoid_dir := Vector3.ZERO
var avoid_t := 0.0
var soar_center := Vector3.ZERO
var soar_angle := 0.0
var dive_abort := false
var call_t := 0.0
var mate_ready := false
var lay_target: Dictionary = {}
var tree_goal: Dictionary = {}


func _init(creature: Creature) -> void:
	c = creature
	w = creature.world
	think_t = randf() * 0.5
	call_t = randf_range(5.0, 30.0)
	soar_center = c.home
	soar_angle = randf() * TAU
	if c.sp.get("grazer", false):
		state = "graze"


func is_friend(o: Creature) -> bool:
	if o.species_id != c.species_id:
		return false
	return c.sp.get("pack", false) or c.sp.get("herd", false) or c.species_id in ["fish", "crow", "grasshopper", "frog", "mouse", "skink"]


func set_state(s: String) -> void:
	if s != state:
		state = s
		state_t = 0.0
		has_goal = false
		pause_t = 0.0
		c.posturing = false
		c.resting = false
		c.stalking = false
		c.sprinting = false
		if c.action == "eat" or c.action == "drink":
			c.cancel_action()


func on_damaged(attacker: Creature, _amount: float) -> void:
	if attacker == null:
		return
	memory[attacker.id] = 1.0
	think_t = 0.0
	# decide immediately: fight back or flee
	if _should_fight(attacker):
		target = attacker
		set_state("fight")
	else:
		threat = attacker
		_start_flee(attacker)


func _should_fight(o: Creature) -> bool:
	if c.sp.courage <= 0.05:
		return false
	if c.health_frac() < c.sp.flee_hp:
		return false
	var mine: float = c.mass * c.health_frac() * (c.sp.dmg + 0.3)
	var theirs: float = o.mass * o.health_frac() * (o.sp.dmg + 0.3)
	if c.sp.get("pack", false):
		mine *= 1.0 + 0.7 * _count_friends(12.0)
	var ratio: float = theirs / maxf(mine, 0.0001)
	return ratio < 0.6 + c.sp.courage * 1.2


func _count_friends(r: float) -> int:
	var n := 0
	for o in w.query(c.position, r):
		var oc: Creature = o
		if oc != c and oc.alive and is_friend(oc):
			n += 1
	return n


# ------------------------------------------------------------------ main loop

func update(dt: float) -> void:
	state_t += dt
	think_t -= dt
	call_t -= dt
	if avoid_t > 0.0:
		avoid_t -= dt
	if think_t <= 0.0:
		think_t = randf_range(0.25, 0.45) if c.lod == 0 else randf_range(0.6, 1.0)
		for k in memory.keys():
			memory[k] -= 0.02
			if memory[k] <= 0.0:
				memory.erase(k)
		_think()
	_act(dt)
	if call_t <= 0.0:
		call_t = randf_range(12.0, 40.0)
		var idle: String = c.sp.sounds.get("idle", "")
		if idle != "" and _is_active_time() and c.lod == 0:
			var dist := 120.0 if c.species_id in ["dingo", "eagle", "crow"] else 45.0
			Sfx.play_at(idle, c.head_pos(), -3.0, 1.0, dist)


func _is_active_time() -> bool:
	var h: float = w.hour
	match c.sp.active:
		"day":
			return h > 6.3 and h < 18.6
		"dusk":
			return (h > 5.0 and h < 10.0) or (h > 15.5 and h < 21.0)
		"dusk_night":
			return h > 16.5 or h < 8.5
		"day_any":
			return h > 5.5 and h < 20.0
	return true


func _is_valid(o) -> bool:
	return o != null and is_instance_valid(o) and not o.removed


func _think() -> void:
	if c.carried_by != null:
		return
	# Special species handled in their own think.
	if c.sp.get("raptor", false):
		_think_raptor()
		return
	if c.species_id == "croc":
		_think_croc()
		return
	if c.sp.get("fish", false):
		_think_fish()
		return
	var neigh: Array = w.query(c.position, maxf(c.sp.detect, 6.0) * 1.2)
	# ---- threats
	var best_threat: Creature = null
	var best_danger := 0.0
	var best_prey: Creature = null
	var best_prey_score := 0.0
	var rival: Creature = null
	var rival_d := 1e9
	var mate: Creature = null
	for o in neigh:
		var oc: Creature = o
		if oc == c or not oc.alive or oc.removed or oc.carried_by != null:
			continue
		var d := c.position.distance_to(oc.position)
		var perceive: float = c.sp.detect * _perceive_mult(oc)
		if d > perceive and oc != c.last_attacker:
			continue
		var danger := _danger(oc, d)
		if danger > best_danger:
			best_danger = danger
			best_threat = oc
		if c.species_id == "monitor" and oc.species_id == "monitor":
			if d < rival_d:
				rival_d = d
				rival = oc
		if c.can_hunt(oc) and c.hunger > 0.35 and not oc.sheltered:
			var s := oc.mass / (d + 1.0)
			if memory.has(oc.id):
				s *= 0.2
			if s > best_prey_score:
				best_prey_score = s
				best_prey = oc
	# ---- 0. refuge up a tree
	if state == "tree":
		var danger_near := best_threat != null and best_danger > 0.2
		if state_t < 12.0 or danger_near or (_is_valid(threat) and threat.alive and c.position.distance_to(threat.position) < 10.0):
			return
		set_state("wander")
		return
	# ---- 1. flee when hurt
	if c.health_frac() < c.sp.flee_hp and _is_valid(c.last_attacker) and w.time - c.last_hit_time < 10.0:
		if state != "flee":
			_start_flee(c.last_attacker)
		return
	# ---- 2. flee / hide from danger
	var fear_threshold: float = 0.25 + c.sp.courage * 0.6
	if best_threat != null and best_danger > fear_threshold:
		if state == "fight" and target == best_threat and _should_fight(best_threat):
			pass
		elif state != "flee" or threat != best_threat:
			_start_flee(best_threat)
			return
		else:
			return
	if state == "flee":
		if _is_valid(threat) and threat.alive and c.position.distance_to(threat.position) < c.sp.detect * 1.1 and flee_t < 14.0:
			return
		if state_t < 3.0:
			return
		set_state("rest" if c.sp.get("hides", false) else "wander")
	# ---- 3. ongoing fight
	if state == "fight":
		if _is_valid(target) and target.alive and state_t < 25.0 and c.position.distance_to(target.position) < c.sp.detect * 1.3:
			if not _should_fight(target):
				threat = target
				_start_flee(target)
			return
		set_state("wander")
	# ---- 4. monitor social behaviour
	if c.species_id == "monitor" and rival != null:
		if _think_monitor_social(rival, rival_d):
			return
	if state in ["posture", "retreat", "chase_off", "court"]:
		if state_t < 10.0:
			return
		set_state("wander")
	# ---- 5. turkey guarding its mound
	if c.species_id == "turkey" and not mound.is_empty():
		for o in neigh:
			var oc2: Creature = o
			if oc2.alive and oc2 != c and oc2.species_id != "turkey" and oc2.mass < c.mass * 0.3 and oc2.mass > 0.01 and oc2.position.distance_to(Vector3(mound.p.x, 0, mound.p.y)) < 7.0:
				target = oc2
				set_state("fight")
				Sfx.play_at("turkey_call", c.head_pos(), 0.0, 1.0, 40.0, 2.0)
				return
	# ---- 6. hunting
	if state == "hunt":
		var chase_limit: float = c.sp.get("chase_time", 12.0)
		if _is_valid(target) and target.alive and not target.sheltered and state_t < chase_limit and c.position.distance_to(target.position) < c.sp.detect * 1.6:
			return
		if _is_valid(target) and not target.alive and target.meat > 0.0:
			set_state("eat")
			return
		if _is_valid(target):
			memory[target.id] = 0.6   # lose interest for a while
		target = null
		set_state("wander")
	if state == "eat":
		if _is_valid(target) and target.meat > 0.0 and c.hunger > 0.05:
			return
		target = null
		set_state("wander")
	if state == "raid":
		if not mound.is_empty() and mound.get("eggs", 0) > 0 and c.hunger > 0.1 and state_t < 30.0:
			return
		set_state("wander")
	if best_prey != null and c.hunger > 0.4 and _is_active_time():
		target = best_prey
		set_state("hunt")
		if c.species_id == "dingo":
			_pack_join(best_prey)
		return
	# ---- 7. carrion
	if c.sp.get("carrion", false) and c.hunger > 0.3:
		var carc := _find_carcass()
		if carc != null:
			target = carc
			set_state("eat")
			return
	# ---- 8. monitors raid turkey mounds for eggs
	if c.species_id == "monitor" and c.hunger > 0.5 and c.mass > 0.2:
		var tm := _nearest_turkey_mound(45.0)
		if not tm.is_empty():
			mound = tm
			set_state("raid")
			return
	# ---- 9. drink
	if c.thirst > 0.7 and not c.sp.get("aquatic", false) and not c.sp.get("flies", false) and c.species_id not in ["grasshopper", "frog", "fish"]:
		if state != "drink":
			var shore: Vector3 = w.terrain.nearest_shore(Vector2(c.position.x, c.position.z), 80.0)
			if shore.y > -900.0:
				goal = shore
				has_goal = true
				set_state("drink")
				goal = shore
				has_goal = true
		return
	if state == "drink":
		if state_t < 25.0 and c.thirst > 0.05:
			return
		set_state("wander")
	# ---- 10. schedule
	if not _is_active_time():
		if state != "sleep":
			set_state("sleep")
		return
	if state == "sleep":
		set_state("wander")
	if c.species_id == "monitor" and w.hour < 8.6 and w.hour > 6.0 and state != "bask":
		set_state("bask")
		return
	if state == "bask":
		if w.hour < 9.0 and state_t < 90.0:
			return
		set_state("wander")
	if c.sp.get("pack", false):
		_pack_follow()
	if state in ["wander", "graze", "patrol", "follow", "rest"]:
		return
	set_state("graze" if c.sp.get("grazer", false) else "wander")


func _perceive_mult(o: Creature) -> float:
	var m := o.visibility
	# bigger things are easier to spot
	m *= clampf(0.55 + 0.25 * log(maxf(o.mass, 0.0001) / maxf(c.mass, 0.0001) + 1.0) + o.size * 0.1, 0.35, 1.6)
	if o.speed > o.walk_speed() * 1.1:
		m *= 1.35
	var night: bool = w.hour < 5.8 or w.hour > 19.2
	if night and c.sp.active in ["day", "day_any"]:
		m *= 0.45
	if o.flying:
		m = maxf(m, 0.8)
	return m


## How dangerous `o` is for this creature (0 none .. 1+ very).
func _danger(o: Creature, d: float) -> float:
	var near := clampf(1.0 - d / maxf(c.sp.detect, 1.0), 0.0, 1.0)
	if o.species_id == c.species_id:
		if c.species_id == "monitor" and o.can_hunt(c) and o.hunger > 0.5:
			return 0.5 + near * 0.5
		return 0.0
	var danger := 0.0
	if o.can_hunt(c):
		danger = 0.55 + near * 0.6
		if o.brain != null and o.brain.get("target") == c:
			danger += 0.4
		if o.is_avatar():
			danger += 0.1
	elif o.mass > c.mass * 4.0 and o.sp.eats.size() > 0:
		danger = 0.35 * near + (0.3 if d < 3.0 + o.length else 0.0)
	elif o.mass > c.mass * 6.0 and d < 2.0 + o.length * 1.5:
		danger = 0.3 + near * 0.3     # startle from anything big nearby
	if memory.has(o.id):
		danger += memory[o.id] * 0.5
	if c.sp.get("aquatic", false):
		danger *= 0.5 if not o.swimming else 1.0
	return danger


func _rival_backed_down(from: Creature) -> void:
	if from == null or c.species_id != "monitor":
		return
	if from.is_player and w.player_life != null:
		w.player_life.notify_rival_fled(c)
	elif from.net_mode == 1:
		Net.send_event(from.net_peer, "rival_fled", "", 0.0, c.id)


func _start_flee(from: Creature) -> void:
	_rival_backed_down(from)
	threat = from
	flee_t = 0.0
	set_state("flee")
	threat = from
	var alert: String = c.sp.sounds.get("alert", "")
	if alert != "" and c.lod == 0:
		Sfx.play_at(alert, c.head_pos(), -2.0, 1.0, 50.0, 1.5)
	# herd alarm
	if c.sp.get("herd", false):
		for o in w.query(c.position, 25.0):
			var oc: Creature = o
			if oc != c and oc.alive and oc.species_id == c.species_id and oc.brain != null and oc.brain.state != "flee":
				oc.brain._start_flee(from)
	if c.can_climb():
		var tr: Dictionary = w.terrain.nearest_tree(Vector2(c.position.x, c.position.z), 14.0)
		if not tr.is_empty():
			tree_goal = tr
			state = "tree"
			state_t = 0.0
			return
	if c.sp.get("hides", false):
		var sh: Dictionary = w.terrain.nearest_shelter(Vector2(c.position.x, c.position.z), c.mass, 12.0)
		if not sh.is_empty():
			goal = Vector3(sh.p.x, 0, sh.p.y)
			has_goal = true
	if c.species_id in ["crow", "turkey"]:
		c.flying = true
		c.fly_alt = 6.0 if c.species_id == "crow" else 2.5
		Sfx.play_at("wings", c.position, -4.0, 1.0, 30.0)


func _find_carcass() -> Creature:
	var best: Creature = null
	var bd: float = c.sp.get("smell", c.sp.detect)
	for carc in w.carcasses:
		var cc: Creature = carc
		if cc.removed or cc.meat <= 0.01 or cc.carried_by != null:
			continue
		# only bother with carcasses worth it relative to our size
		if cc.meat < c.mass * 0.03 and cc.meat < 0.02:
			continue
		var d := c.position.distance_to(cc.position)
		if d < bd:
			bd = d
			best = cc
	return best


func _nearest_turkey_mound(max_d: float) -> Dictionary:
	var best := {}
	var bd := max_d
	for m in w.terrain.turkey_mounds:
		if m.eggs <= 0:
			continue
		var d := Vector2(c.position.x, c.position.z).distance_to(m.p)
		if d < bd:
			bd = d
			best = m
	return best


func _pack_join(prey: Creature) -> void:
	for o in w.query(c.position, 40.0):
		var oc: Creature = o
		if oc != c and oc.alive and oc.species_id == c.species_id and oc.brain != null and oc.brain.state in ["wander", "follow", "rest"]:
			oc.brain.target = prey
			oc.brain.set_state("hunt")


func _pack_follow() -> void:
	if leader == null or not _is_valid(leader) or not leader.alive:
		leader = null
		for o in w.creatures:
			var oc: Creature = o
			if oc.alive and oc.species_id == c.species_id and oc.id < c.id:
				leader = oc
				break
	if leader != null and leader != c and state in ["wander", "graze", "rest"] and c.position.distance_to(leader.position) > 10.0:
		set_state("follow")


# ------------------------------------------------------------------ monitors

func _think_monitor_social(o: Creature, d: float) -> bool:
	var adult_c := c.mass > 5.0
	var adult_o := o.mass > 5.0
	# opposite-sex adults tolerate each other (and may court)
	if adult_c and adult_o and o.sex != c.sex:
		if state in ["posture", "chase_off", "fight"] and target == o:
			set_state("wander")
		look_point = o.position if d < 8.0 else null
		return false
	var in_terr := c.territory > 0.0 and o.position.distance_to(c.home) < c.territory
	var close := d < maxf(3.0, c.length * 3.5)
	if not in_terr and not close:
		return false
	if o.can_hunt(c):
		return false   # handled by danger
	var ratio := o.intimidation() / maxf(c.intimidation(), 0.0001)
	if in_terr:
		ratio /= 1.25
	if c.can_hunt(o) and c.hunger > 0.45:
		target = o
		set_state("hunt")
		return true
	if state == "fight" and target == o:
		return true
	if state == "retreat":
		return state_t < 8.0
	if ratio < 0.45:
		if state != "chase_off":
			target = o
			set_state("chase_off")
			Sfx.play_at("hiss_big" if c.mass > 3.0 else "hiss", c.head_pos(), 0.0, 1.0, 35.0, 2.0)
		return true
	if ratio <= 1.8:
		if state != "posture" and state != "fight":
			target = o
			set_state("posture")
			posture_limit = randf_range(2.5, 4.5)
			rival_start_d = d
		elif state == "posture" and state_t > posture_limit:
			if o.is_avatar() and o.posturing:
				ratio *= 1.1
			var still_close := c.position.distance_to(o.position) < maxf(rival_start_d * 1.1, c.length * 2.5)
			var o_backing: bool = o.brain != null and o.brain.get("state") == "retreat"
			if o.is_avatar() and o.speed > o.walk_speed() * 0.6:
				var away := (o.position - c.position).normalized().dot(o.fwd())
				o_backing = away > 0.3
			if o_backing:
				set_state("chase_off")
				target = o
			elif still_close:
				if ratio < 1.15 or randf() < c.sp.aggression * 0.6:
					target = o
					set_state("fight")
				else:
					threat = o
					set_state("retreat")
			else:
				set_state("patrol")
		return true
	# rival much bigger: submit and leave
	threat = o
	if state != "retreat":
		set_state("retreat")
		_rival_backed_down(o)
	return true


# ------------------------------------------------------------------ raptor

func _think_raptor() -> void:
	if not _is_active_time():
		if state != "roost":
			set_state("roost")
		return
	if state == "roost" or state not in ["soar", "stalk_air", "dive", "strike_ground", "eat", "climb"]:
		set_state("soar")
	if c.health_frac() < c.sp.flee_hp and w.time - c.last_hit_time < 6.0:
		set_state("climb")
		return
	match state:
		"soar":
			if c.hunger > 0.35 and state_t > 6.0:
				var best: Creature = null
				var bs := 0.0
				for o in w.query(Vector3(c.position.x, 0, c.position.z), c.sp.detect):
					var oc: Creature = o
					if not c.can_hunt(oc) or oc.sheltered or oc.swimming:
						continue
					var vis := oc.visibility * (1.5 if oc.speed > 0.2 else 0.7)
					if vis < 0.3:
						continue
					var s := vis * oc.mass / (1.0 + Vector2(oc.position.x - c.position.x, oc.position.z - c.position.z).length() * 0.05)
					if oc.is_avatar():
						s *= 1.6
					if s > bs:
						bs = s
						best = oc
				if best != null:
					target = best
					set_state("stalk_air")
					Sfx.play_at("eagle_screech", c.position, 4.0, 1.0, 160.0)
			elif c.hunger <= 0.35:
				var carc := _find_carcass()
				if carc != null and c.hunger > 0.15:
					target = carc
					set_state("eat")
		"stalk_air":
			if not _is_valid(target) or not target.alive or target.sheltered or state_t > 12.0:
				set_state("soar")
			elif state_t > 3.0:
				set_state("dive")
				dive_abort = false
		"dive":
			if not _is_valid(target) or not target.alive:
				set_state("climb")
			elif target.sheltered or target.cover > 0.75:
				set_state("climb")
		"strike_ground":
			if state_t > 1.2:
				set_state("climb")
		"eat":
			if not _is_valid(target) or target.meat <= 0.0 or c.hunger < 0.05:
				set_state("climb")
		"climb":
			if c.position.y - w.terrain.height(c.position.x, c.position.z) > 20.0 or state_t > 8.0:
				set_state("soar")


# ------------------------------------------------------------------ crocodile

func _think_croc() -> void:
	var in_water: bool = w.terrain.water_depth(c.position.x, c.position.z) > 0.4
	if state == "lunge":
		if state_t > 1.4:
			set_state("return")
		return
	if state == "eat":
		if _is_valid(target) and target.meat > 0.0 and c.hunger > 0.05:
			return
		set_state("return")
	if c.health_frac() < c.sp.flee_hp and w.time - c.last_hit_time < 8.0:
		set_state("return")
		return
	# ambush anything catchable near/in the water
	if c.hunger > 0.3:
		for o in w.query(c.position, 9.0):
			var oc: Creature = o
			if oc == c or not c.can_hunt(oc) or oc.flying:
				continue
			var od: float = w.terrain.water_depth(oc.position.x, oc.position.z)
			var near_water := od > -0.35
			if not near_water:
				continue
			var d := c.position.distance_to(oc.position)
			var trigger := 7.0 if oc.action == "drink" or oc.swimming else 4.5
			if d < trigger and randf() < (0.9 if oc.action == "drink" or oc.swimming else 0.35):
				target = oc
				set_state("lunge")
				Sfx.play_at("croc_lunge", c.position, 3.0, 1.0, 60.0)
				return
		var carc := _find_carcass()
		if carc != null and w.terrain.water_depth(carc.position.x, carc.position.z) > -3.0:
			target = carc
			set_state("eat")
			return
	if state == "return":
		if in_water and state_t > 2.0:
			set_state("lurk")
		return
	if w.hour > 11.0 and w.hour < 14.5 and c.hunger < 0.5:
		if state != "bask":
			set_state("bask")
		return
	if state == "bask" and (w.hour < 11.0 or w.hour > 14.5):
		set_state("return")
		return
	if state not in ["lurk", "cruise", "bask"]:
		set_state("lurk")
	if state == "lurk" and state_t > randf_range(20.0, 40.0):
		set_state("cruise")
	elif state == "cruise" and state_t > 25.0:
		set_state("lurk")


# ------------------------------------------------------------------ fish

func _think_fish() -> void:
	for o in w.query(c.position, 5.0):
		var oc: Creature = o
		if oc != c and oc.alive and oc.mass > c.mass * 3.0 and (oc.swimming or oc.species_id == "croc" or w.terrain.water_depth(oc.position.x, oc.position.z) > -0.3):
			var d := c.position.distance_to(oc.position)
			if d < 2.5 + oc.length:
				threat = oc
				if state != "flee":
					set_state("flee")
					threat = oc
				return
	if state == "flee" and state_t < 2.5:
		return
	if state != "wander":
		set_state("wander")


# ------------------------------------------------------------------ actions per frame

func _act(dt: float) -> void:
	if c.carried_by != null:
		c.halt()
		return
	if state == "tree":
		_act_tree(dt)
		return
	if c.climbing:
		# come down before doing anything else
		c.climb_in = Vector2(0, -1)
		c.resting = false
		return
	match state:
		"wander", "patrol", "graze":
			_act_wander(dt)
		"follow":
			if _is_valid(leader) and leader.alive:
				var off := Vector3(sin(c.id * 1.7), 0, cos(c.id * 1.7)) * 4.0
				var gp := leader.position + off
				if c.position.distance_to(gp) > 3.0:
					_go(gp, c.walk_speed() if c.position.distance_to(gp) < 15.0 else c.run_speed() * 0.6)
				else:
					c.halt()
					if state_t > 4.0:
						set_state("wander")
			else:
				set_state("wander")
		"rest", "sleep", "roost":
			_act_rest(dt)
		"bask":
			_act_bask(dt)
		"flee":
			_act_flee(dt)
		"hunt":
			_act_hunt(dt)
		"fight", "chase_off":
			_act_fight(dt)
		"posture":
			_act_posture(dt)
		"retreat":
			_act_retreat(dt)
		"eat":
			_act_eat(dt)
		"raid":
			_act_raid(dt)
		"drink":
			_act_drink(dt)
		"soar":
			_act_soar(dt)
		"stalk_air":
			_act_stalk_air(dt)
		"dive":
			_act_dive(dt)
		"climb", "strike_ground":
			c.flying = true
			c.fly_alt = 26.0
			c.climb_rate = 5.0
			c.steer(c.fwd(), c.sp.fly_speed * 0.8)
		"lurk", "cruise", "return", "lunge":
			_act_croc(dt)
		_:
			c.halt()


func _go(p: Vector3, spd: float) -> void:
	var d := p - c.position
	d.y = 0
	if d.length() < 0.05:
		c.halt()
		return
	var dir := d.normalized()
	if avoid_t > 0.0:
		dir = (dir + avoid_dir * 1.5).normalized()
	elif c.blocked:
		avoid_dir = dir.rotated(Vector3.UP, (PI * 0.5) * (1.0 if randf() < 0.5 else -1.0))
		avoid_t = 0.8
	c.steer(dir, spd)


func _wander_radius() -> float:
	match c.species_id:
		"monitor":
			return maxf(c.territory, 25.0 + c.size * 40.0)
		"dingo":
			return 70.0
		"wallaby":
			return 35.0
		"mouse", "skink", "frog":
			return 10.0
		"grasshopper":
			return 6.0
		"turkey":
			return 14.0
		"crow":
			return 60.0
	return 20.0


func _act_tree(dt: float) -> void:
	if tree_goal.is_empty():
		set_state("wander")
		return
	if c.climbing:
		var want := minf(2.5 + c.length, c.climb_top())
		c.climb_in = Vector2(0, 1) if c.climb_h < want else Vector2.ZERO
		c.sprinting = true
		c.resting = c.climb_h >= want
		look_point = threat.position if _is_valid(threat) else null
		return
	var tp := Vector3(tree_goal.p.x, c.position.y, tree_goal.p.y)
	var d: float = Vector2(c.position.x - tree_goal.p.x, c.position.z - tree_goal.p.y).length() - tree_goal.r0
	c.sprinting = true
	if d < c.radius + c.length * 0.2 + 0.15:
		c.start_climb(tree_goal)
	else:
		_go(tp, c.run_speed())
	if state_t > 10.0 and not c.climbing:
		set_state("wander")


func _act_wander(dt: float) -> void:
	if pause_t > 0.0:
		pause_t -= dt
		c.halt()
		if c.species_id == "monitor" and randf() < dt * 0.5:
			tongue_now = true
		return
	if not has_goal or c.position.distance_to(goal) < maxf(0.4, c.length * 0.8) or c.blocked and randf() < 0.1:
		if has_goal:
			pause_t = randf_range(1.0, 5.0) if state != "graze" else randf_range(2.0, 8.0)
			has_goal = false
			if state == "graze" and c.rig != null and randf() < 0.6:
				c.start_eat(null)   # grazing animation (no food target)
			return
		var center := c.home
		if c.sp.get("aquatic", false):
			var wp: Vector2 = w.terrain.random_water_point(Vector2(center.x, center.z), _wander_radius(), 0.5)
			if wp.x == INF:
				wp = Vector2(c.position.x, c.position.z)
			goal = Vector3(wp.x, 0, wp.y)
		else:
			var lp: Vector2 = w.terrain.random_land_point(Vector2(center.x, center.z), _wander_radius(), 0.15)
			goal = Vector3(lp.x, 0, lp.y)
		has_goal = true
		if c.species_id == "crow" and c.position.distance_to(goal) > 12.0:
			c.flying = true
			c.fly_alt = 7.0
	if c.action == "eat" and c.eat_target == null:
		if c.action_t > 2.5:
			c.cancel_action()
		return
	var spd := c.walk_speed() * (0.6 if state == "graze" else 1.0)
	if c.flying:
		spd = c.sp.get("fly_speed", 6.0)
		if Vector2(goal.x - c.position.x, goal.z - c.position.z).length() < 3.0:
			c.fly_alt = 0.0
			if c.position.y - w.terrain.height(c.position.x, c.position.z) < 0.3:
				c.flying = false
	if c.species_id == "grasshopper" and randf() < dt * 0.3:
		c.knock += c.fwd() * 2.0
	_go(goal, spd)


func _act_rest(dt: float) -> void:
	# head to cover first (shelter for small, bush/shade otherwise), then rest
	if not has_goal and state_t < 0.5:
		var p2 := Vector2(c.position.x, c.position.z)
		var sh: Dictionary = w.terrain.nearest_shelter(p2, c.mass, 25.0)
		if sh.is_empty():
			var b: Dictionary = w.terrain.nearest_bush(p2, 25.0)
			if not b.is_empty():
				goal = Vector3(b.p.x, 0, b.p.y)
				has_goal = true
		else:
			goal = Vector3(sh.p.x, 0, sh.p.y)
			has_goal = true
	if c.flying:
		c.fly_alt = 0.0
		if c.position.y - w.terrain.height(c.position.x, c.position.z) < 0.3:
			c.flying = false
	if has_goal and c.position.distance_to(Vector3(goal.x, c.position.y, goal.z)) > maxf(0.5, c.length):
		_go(goal, c.walk_speed())
		c.resting = false
	else:
		has_goal = false
		c.halt()
		c.resting = true


func _act_bask(dt: float) -> void:
	if not has_goal and state_t < 0.5 and c.species_id == "croc":
		var sh: Vector3 = w.terrain.nearest_shore(Vector2(c.position.x, c.position.z), 30.0)
		goal = sh if sh.y > -900.0 else c.position
		has_goal = true
	if not has_goal and state_t < 0.5:
		var s: Dictionary = w.terrain.nearest_slab(Vector2(c.position.x, c.position.z), 35.0)
		if not s.is_empty():
			goal = Vector3(s.p.x, 0, s.p.y)
		else:
			goal = c.position
		has_goal = true
	if c.position.distance_to(Vector3(goal.x, c.position.y, goal.z)) > maxf(0.6, c.length * 0.5):
		_go(goal, c.walk_speed() * 0.8)
		c.resting = false
	else:
		c.halt()
		c.resting = true


func _act_flee(dt: float) -> void:
	flee_t += dt
	c.sprinting = true
	c.resting = false
	if c.species_id in ["grasshopper", "frog"]:
		# escape in discrete hops, then freeze and rely on camouflage
		pause_t -= dt
		c.halt()
		if pause_t <= 0.0 and _is_valid(threat):
			var away := c.position - threat.position
			away.y = 0
			var dir := away.normalized().rotated(Vector3.UP, randf_range(-0.8, 0.8)) if away.length() > 0.01 else c.fwd()
			var probe := c.position + dir * 1.0
			if c.species_id == "grasshopper" and w.terrain.water_depth(probe.x, probe.z) > 0.0:
				dir = -dir
			c.yaw = atan2(dir.x, dir.z)
			c.knock += dir * (3.2 if c.species_id == "grasshopper" else 2.6)
			pause_t = randf_range(0.9, 2.2)
			var snd: String = c.sp.sounds.get("alert", "")
			if snd != "" and c.lod == 0:
				Sfx.play_at(snd, c.position, -8.0, 1.0, 12.0, 0.5)
		if flee_t > 5.0:
			set_state("wander")
		return
	if c.species_id in ["crow", "turkey"] and c.flying:
		if _is_valid(threat):
			var away := c.position - threat.position
			away.y = 0
			c.steer(away.normalized() if away.length() > 0.1 else c.fwd(), c.sp.fly_speed)
		if flee_t > (4.0 if c.species_id == "turkey" else 6.0):
			c.fly_alt = 0.0
			if c.position.y - w.terrain.height(c.position.x, c.position.z) < 0.3:
				c.flying = false
				set_state("wander")
		return
	if has_goal and c.sp.get("hides", false):
		if c.position.distance_to(Vector3(goal.x, c.position.y, goal.z)) > 0.3:
			_go(goal, c.run_speed())
		else:
			c.halt()
			c.resting = true
		return
	if not _is_valid(threat):
		c.halt()
		return
	var away2 := c.position - threat.position
	away2.y = 0
	if away2.length() < 0.01:
		away2 = -c.fwd()
	var dir := away2.normalized()
	# bias away from water for non-swimmers, toward water for swimmers fleeing land predators
	var probe := c.position + dir * 3.0
	if not c.sp.get("swims", false) and w.terrain.water_depth(probe.x, probe.z) > 0.1:
		dir = dir.rotated(Vector3.UP, PI * 0.5 * (1.0 if (c.id % 2) == 0 else -1.0))
	if c.species_id == "monitor" and c.mass < 5.0:
		# small monitors dash for cover
		var sh: Dictionary = w.terrain.nearest_shelter(Vector2(c.position.x, c.position.z), c.mass, 15.0)
		if not sh.is_empty():
			var to := Vector3(sh.p.x, c.position.y, sh.p.y) - c.position
			if to.normalized().dot(dir) > -0.3:
				dir = to.normalized()
	if c.sp.get("fish", false):
		dir = dir.rotated(Vector3.UP, sin(flee_t * 3.0) * 0.6)
	_go(c.position + dir * 5.0, c.run_speed())


func _act_hunt(dt: float) -> void:
	if not _is_valid(target) or not target.alive:
		c.halt()
		return
	var d := c.position.distance_to(target.position)
	look_point = target.position
	var close := d < c.length * 1.5 + target.radius + 0.8
	if d > c.sp.detect * 0.45 and state_t < 8.0 and c.species_id in ["monitor", "dingo"]:
		c.stalking = true
		c.sprinting = false
		_go(target.position, c.walk_speed() * 0.7)
	else:
		c.stalking = false
		c.sprinting = true
		var lead := target.position + target.fwd() * target.speed * clampf(d / maxf(c.run_speed(), 0.1), 0.0, 1.0)
		_go(lead, c.run_speed())
	if close:
		var hd := c.head_pos().distance_to(target.position) - target.radius
		if hd < c.reach() * 1.4 + 0.1:
			c.face(target.position, dt, 10.0)
			c.try_bite()


func _act_fight(dt: float) -> void:
	if not _is_valid(target) or not target.alive:
		set_state("wander")
		return
	look_point = target.position
	var d := c.position.distance_to(target.position)
	c.sprinting = state == "chase_off" or d > c.length * 3.0
	if state == "chase_off":
		if state_t > 8.0 or (c.territory > 0.0 and target.position.distance_to(c.home) > c.territory * 1.2):
			set_state("patrol")
			return
		if d > c.sp.detect * 1.2:
			set_state("patrol")
			return
	var hd := c.head_pos().distance_to(target.position) - target.radius
	if hd < c.reach() * 1.3 + 0.08:
		c.face(target.position, dt, 8.0)
		c.halt()
		if c.action == "" and c.flinch <= 0.0:
			var to := target.position - c.position
			var behind := absf(wrapf(atan2(to.x, to.z) - c.yaw, -PI, PI)) > PI * 0.6
			if c.sp.rig == "reptile" and behind and randf() < 0.6:
				c.try_whip()
			elif randf() < 0.55:
				c.try_bite()
			elif c.species_id == "monitor" and randf() < 0.3:
				c.try_whip()
	else:
		# circle a bit before closing in
		var to2 := (target.position - c.position).normalized()
		var circ := to2.rotated(Vector3.UP, 0.5 * sin(state_t * 1.3 + c.id))
		_go(c.position + circ * 3.0, c.run_speed() if d > c.length * 2.0 else c.walk_speed())


func _act_posture(dt: float) -> void:
	if not _is_valid(target):
		set_state("wander")
		return
	look_point = target.position
	c.posturing = true
	c.face(target.position, dt, 2.0)
	var d := c.position.distance_to(target.position)
	if d > c.length * 2.2:
		_go(target.position, c.walk_speed() * 0.4)
	else:
		c.halt()


func _act_retreat(dt: float) -> void:
	c.posturing = false
	var from := threat if _is_valid(threat) else target
	if from == null or not _is_valid(from):
		set_state("wander")
		return
	var away := c.position - from.position
	away.y = 0
	_go(c.position + away.normalized() * 5.0, c.walk_speed() * 1.3 if state_t < 3.0 else c.walk_speed())
	c.sprinting = state_t < 3.0
	if state_t > 6.0 and c.territory > 0.0 and from.position.distance_to(c.home) < c.territory:
		# give up the territory centre for now
		c.home = c.position + away.normalized() * 20.0


func _act_eat(dt: float) -> void:
	if c.sp.get("raptor", false):
		c.flying = true
	if not _is_valid(target) or target.meat <= 0.0:
		c.halt()
		return
	var hd := c.head_pos().distance_to(target.position)
	if hd > c.reach() + target.length * 0.5 + 0.3:
		if c.sp.get("raptor", false) or (c.species_id == "crow" and hd > 10.0):
			c.flying = true
			c.fly_alt = 0.0 if hd < 6.0 else 8.0
			c.steer((target.position - c.position).normalized(), c.sp.fly_speed * (0.5 if hd < 6.0 else 1.0))
			if hd < 2.0 and c.position.y - w.terrain.height(c.position.x, c.position.z) < 0.4:
				c.flying = false
		else:
			if c.flying:
				c.fly_alt = 0.0
				if c.position.y - w.terrain.height(c.position.x, c.position.z) < 0.3:
					c.flying = false
			_go(target.position, c.walk_speed())
	else:
		c.flying = false
		c.halt()
		c.face(target.position, dt, 4.0)
		if c.action == "":
			c.start_eat(target)
		# scavengers keep watch
		if c.species_id == "crow" and randf() < dt * 0.3:
			Sfx.play_at("crow_caw_2", c.head_pos(), -6.0, 1.0, 60.0, 3.0)


func _act_raid(dt: float) -> void:
	if mound.is_empty():
		set_state("wander")
		return
	var mp := Vector3(mound.p.x, c.position.y, mound.p.y)
	var d := c.position.distance_to(mp)
	if d > mound.r + c.length * 0.4:
		_go(mp, c.walk_speed())
	else:
		c.halt()
		c.face(mp, dt, 3.0)
		if c.action == "" and state_t > 1.0 and randf() < dt * 0.8:
			c.start_eat(mound)


func _act_drink(dt: float) -> void:
	if not has_goal:
		set_state("wander")
		return
	var d := Vector2(goal.x - c.position.x, goal.z - c.position.z).length()
	if d > maxf(0.4, c.length * 0.5):
		_go(goal, c.walk_speed())
	else:
		c.halt()
		# face the water
		var shore_dir := Vector3.ZERO
		for k in 8:
			var a := TAU * k / 8.0
			var q := c.position + Vector3(cos(a), 0, sin(a)) * 2.0
			if w.terrain.water_depth(q.x, q.z) > 0.05:
				shore_dir += Vector3(cos(a), 0, sin(a))
		if shore_dir.length() > 0.1:
			c.face(c.position + shore_dir, dt, 3.0)
		if c.action == "" and state_t > 1.0:
			c.start_drink()
		if c.thirst <= 0.05:
			c.cancel_action()
			set_state("wander")


func _act_soar(dt: float) -> void:
	c.flying = true
	c.fly_alt = 28.0 + sin(state_t * 0.1 + c.id) * 5.0
	c.climb_rate = 3.0
	soar_angle += dt * 0.12
	var r := 38.0
	var p := soar_center + Vector3(cos(soar_angle), 0, sin(soar_angle)) * r
	# drift the circling centre over the map
	if state_t > 40.0 and randf() < dt * 0.05:
		var np: Vector2 = w.terrain.random_land_point(Vector2(c.home.x, c.home.z), 90.0, 0.0)
		soar_center = Vector3(np.x, 0, np.y)
	c.steer(p - c.position, c.sp.fly_speed * 0.8)


func _act_stalk_air(dt: float) -> void:
	if not _is_valid(target):
		return
	c.flying = true
	c.fly_alt = 18.0
	look_point = target.position
	var over := target.position + (c.position - target.position).normalized() * 14.0
	c.steer(over - c.position, c.sp.fly_speed)


func _act_dive(dt: float) -> void:
	if not _is_valid(target):
		set_state("climb")
		return
	c.flying = true
	var tp := target.position + Vector3.UP * target.length * 0.1
	var d := c.position.distance_to(tp)
	var hd := Vector2(tp.x - c.position.x, tp.z - c.position.z).length()
	c.fly_alt = clampf(hd * 0.6, 0.0, 30.0)
	c.climb_rate = 14.0
	c.steer(tp - c.position, c.sp.fly_speed * 2.1)
	if d < 1.2 + target.radius:
		# talon strike
		if target.alive and not target.sheltered and target.iframes <= 0.0:
			var dmg := c.bite_damage()
			target.take_damage(dmg, c, "talons")
			Sfx.play_at("wings", c.position, 2.0, 0.8, 60.0)
			if not target.alive and target.mass < c.mass * 0.5:
				target.carried_by = c
				c.hunger = 0.0
		set_state("strike_ground")
	elif state_t > 6.0:
		set_state("climb")


func _act_croc(dt: float) -> void:
	var depth: float = w.terrain.water_depth(c.position.x, c.position.z)
	submerged = depth > 0.5 and state in ["lurk", "cruise"]
	match state:
		"lurk":
			c.halt()
			if depth < 0.6:
				var wp: Vector2 = w.terrain.random_water_point(Vector2(c.position.x, c.position.z), 12.0, 0.9)
				if wp.x != INF:
					goal = Vector3(wp.x, 0, wp.y)
					_go(goal, c.sp.get("swim_speed", 2.0) * 0.5)
		"cruise":
			if not has_goal or c.position.distance_to(Vector3(goal.x, c.position.y, goal.z)) < 2.0:
				var wp2: Vector2 = w.terrain.random_water_point(Vector2(c.home.x, c.home.z), 45.0, 0.9)
				if wp2.x != INF:
					goal = Vector3(wp2.x, 0, wp2.y)
					has_goal = true
			_go(goal, c.sp.get("swim_speed", 2.0) * 0.45)
		"return":
			if depth > 0.8:
				c.halt()
			else:
				var wp3: Vector2 = w.terrain.random_water_point(Vector2(c.position.x, c.position.z), 20.0, 1.0)
				if wp3.x != INF:
					_go(Vector3(wp3.x, 0, wp3.y), c.walk_speed() * 1.5)
		"lunge":
			if _is_valid(target) and target.alive:
				c.steer(target.position - c.position, c.sp.run * 3.0)
				c.knock += (target.position - c.position).normalized() * 18.0 * dt * (1.0 if state_t < 0.5 else 0.0)
				var hd := c.head_pos().distance_to(target.position) - target.radius
				if hd < c.reach() * 1.2 + 0.3:
					c.try_bite()
			else:
				c.halt()
			if _is_valid(target) and not target.alive and target.meat > 0.0 and state_t > 0.8:
				set_state("eat")
		"bask":
			pass


# bask for crocs: haul out onto a nearby sandbank handled via "bask" in _act dispatch
