class_name PlayerLife
extends RefCounted
## The player's life: nutrition, water, body temperature, growth through life
## stages, ageing, reproduction and life statistics.

signal stage_changed(stage: int)
signal hint(id: String, text: String)
signal message(text: String)

const STAGES := ["Hatchling", "Juvenile", "Subadult", "Adult", "Old"]
const STAGE_MASS := [0.0, 0.25, 1.5, 6.0]
const STAGE_MIN_AGE := [0.0, 200.0, 620.0, 1150.0]    # seconds of life before a stage can be reached
const MAX_MASS := 14.0
const OLD_AGE := 2250.0          # seconds of life before old age can begin
const MIN_ADULT_TIME := 420.0    # at least this long as an adult before ageing
const OLD_SPAN := 540.0          # how long old age lasts at most
const GROWTH_EFF := 3.2

var c: Creature
var w: World
var stage := 0
var food := 70.0          # satiety %
var stomach := 0.0        # kg waiting to be digested
var water := 80.0         # hydration %
var body_temp := 30.0     # deg C
var env_temp := 25.0
var age_t := 0.0
var adult_t := 0.0
var old_t := 0.0
var temp_state := "ok"    # cold, cool, ok, warm, hot
var sleeping := false
var gravid := false
var court_cooldown := 0.0
var lineage := 1
var hints_seen := {}
var stats := {
	"eaten": 0, "kills": 0, "fights_won": 0, "distance": 0.0, "max_mass": 0.04,
	"offspring": 0, "days": 1, "bitten": 0, "biggest_kill": "", "biggest_kill_mass": 0.0,
}
var _hint_t := 1.0
var _save_t := 60.0
var _last_pos := Vector3.ZERO
var _starve_msg_t := 0.0
var _heartbeat := false
var _fought: Dictionary = {}     # monitor ids we've exchanged blows with


func setup(creature: Creature, world: World, data: Dictionary) -> void:
	c = creature
	w = world
	c.is_player = true
	_last_pos = c.position
	if not data.is_empty():
		from_dict(data)
	stage = _compute_stage()
	stats.max_mass = maxf(stats.max_mass, c.mass)


# ------------------------------------------------------------------ queries

func is_full() -> bool:
	return stomach >= c.mass * 0.22 or food >= 100.0


func stage_name() -> String:
	return STAGES[stage]


func growth_progress() -> float:
	if stage >= 3:
		return clampf((c.mass - STAGE_MASS[3]) / (MAX_MASS - STAGE_MASS[3]), 0.0, 1.0)
	var a := log(maxf(c.mass, 0.001) / maxf(STAGE_MASS[stage] if stage > 0 else 0.04, 0.001))
	var b := log(STAGE_MASS[stage + 1] / (STAGE_MASS[stage] if stage > 0 else 0.04))
	return clampf(a / b, 0.0, 1.0)


func can_court() -> bool:
	return stage == 3 and not gravid and court_cooldown <= 0.0 and food > 30.0 and c.health_frac() > 0.4


func _compute_stage() -> int:
	if old_t > 0.0:
		return 4
	for s in range(3, -1, -1):
		if c.mass >= STAGE_MASS[s] * 0.999:
			return s
	return 0


# ------------------------------------------------------------------ update

func update(dt: float) -> void:
	if not c.alive:
		return
	age_t += dt
	court_cooldown = maxf(0.0, court_cooldown - dt)
	var moved := c.position.distance_to(_last_pos)
	if moved < 5.0:
		stats.distance += moved
	_last_pos = c.position
	stats.days = w.day
	_update_temperature(dt)
	_update_metabolism(dt)
	_update_growth(dt)
	_update_ageing(dt)
	_update_sleep(dt)
	_hint_t -= dt
	if _hint_t <= 0.0:
		_hint_t = 0.5
		_check_hints()
	_save_t -= dt
	if _save_t <= 0.0:
		_save_t = 90.0
		if Game.main != null:
			Game.main.autosave()
	var low := c.health_frac() < 0.3
	if low != _heartbeat:
		_heartbeat = low
		Sfx.set_bed("heartbeat", 0.7 if low else 0.0)


func _update_temperature(dt: float) -> void:
	var t := w.terrain
	var air := w.air_temp()
	var elev := w.sun_elevation()
	var shade := t.shade(c.position.x, c.position.z)
	var exposure := (1.0 - shade) * elev
	var env := air + 13.0 * exposure
	if t.on_slab(c.position.x, c.position.z):
		env += 5.0 * elev + (1.5 if w.hour > 17.0 and w.hour < 20.0 else 0.0)
	if c.sheltered:
		env = lerpf(env, 25.0, 0.7)
	if c.swimming:
		env = 23.0
	env_temp = env
	var k := 0.022 / sqrt(maxf(c.size, 0.1))
	if c.swimming:
		k *= 2.0
	body_temp += (env - body_temp) * k * dt
	if c.speed > c.walk_speed() * 1.1:
		body_temp += 0.02 * dt
	body_temp = clampf(body_temp, 10.0, 46.0)
	var f := 1.0
	if body_temp < 18.0:
		f = 0.5
	elif body_temp < 30.0:
		f = lerpf(0.5, 1.0, smoothstep(18.0, 30.0, body_temp))
	elif body_temp > 38.0:
		f = lerpf(1.0, 0.8, smoothstep(38.0, 42.0, body_temp))
	var old_pen := 0.85 if stage == 4 else 1.0
	c.temp_factor = f
	c.speed_mult = old_pen
	if body_temp < 22.0:
		temp_state = "cold"
	elif body_temp < 27.0:
		temp_state = "cool"
	elif body_temp <= 38.5:
		temp_state = "ok"
	elif body_temp <= 41.0:
		temp_state = "warm"
	else:
		temp_state = "hot"
		c.health -= c.max_health * 0.006 * dt
		c.stamina = maxf(0.0, c.stamina - 0.05 * dt)
		if c.health <= 0.0:
			c.die("Heatstroke")


func digest_factor() -> float:
	if body_temp < 20.0:
		return 0.12
	if body_temp < 30.0:
		return lerpf(0.12, 1.0, smoothstep(20.0, 30.0, body_temp))
	if body_temp > 40.0:
		return 0.8
	return 1.0


func _update_metabolism(dt: float) -> void:
	var activity := clampf(c.speed / maxf(0.1, c.walk_speed()), 0.0, 2.0)
	var drain := 0.16 + 0.1 * activity + (0.1 if c.action == "bite" else 0.0)
	if sleeping:
		drain *= 0.35
	food = maxf(0.0, food - drain * dt)
	var wdrain := 0.15 + 0.07 * activity + (0.25 if body_temp > 38.0 else 0.0)
	if sleeping:
		wdrain *= 0.35
	water = maxf(0.0, water - wdrain * dt)
	# digestion
	if stomach > 0.0:
		var d := minf(stomach, c.mass * 0.004 * digest_factor() * dt)
		stomach -= d
		food = minf(100.0, food + d / c.mass * 260.0)
		_grow(d)
	# regeneration
	var since_hit: float = w.time - c.last_hit_time
	if food > 15.0 and water > 15.0 and since_hit > 6.0 and temp_state != "hot":
		var regen := 0.007 * c.temp_factor * (2.2 if c.resting else 1.0) * (0.5 if stage == 4 else 1.0)
		c.health = minf(c.max_health * _old_cap(), c.health + c.max_health * regen * dt)
	if food <= 0.0:
		c.health -= c.max_health * 0.008 * dt
		_starve_msg_t -= dt
		if _starve_msg_t <= 0.0:
			_starve_msg_t = 20.0
			message.emit("You are starving.")
		if c.health <= 0.0:
			c.die("Starvation")
	if water <= 0.0:
		c.health -= c.max_health * 0.01 * dt
		if c.health <= 0.0:
			c.die("Thirst")


func _grow(digested: float) -> void:
	var gm := GROWTH_EFF if food > 25.0 else GROWTH_EFF * 0.3
	var nm := c.mass + digested * gm
	# growth into the next stage waits for the body to mature
	var next := stage + 1
	if next <= 3 and nm >= STAGE_MASS[next] and age_t < STAGE_MIN_AGE[next]:
		nm = minf(nm, STAGE_MASS[next] * 0.995)
	nm = minf(nm, MAX_MASS * (0.97 if stage == 4 else 1.0))
	if absf(nm - c.mass) > 0.00001:
		c.set_mass(nm)
	stats.max_mass = maxf(stats.max_mass, c.mass)


func _update_growth(_dt: float) -> void:
	var s := _compute_stage()
	if s != stage:
		var old := stage
		stage = s
		if s > old:
			stage_changed.emit(s)


func _old_cap() -> float:
	if old_t <= 0.0:
		return 1.0
	return clampf(1.0 - (old_t / OLD_SPAN) * 0.85, 0.1, 1.0)


func _update_ageing(dt: float) -> void:
	if stage >= 3:
		adult_t += dt
	if old_t <= 0.0 and stage == 3 and age_t > OLD_AGE and adult_t > MIN_ADULT_TIME:
		old_t = 0.001
		_update_growth(0.0)
	if old_t > 0.0:
		old_t += dt
		var cap := c.max_health * _old_cap()
		if c.health > cap:
			c.health = move_toward(c.health, cap, c.max_health * 0.01 * dt)
		if old_t >= OLD_SPAN:
			c.die("Old age")


func _update_sleep(_dt: float) -> void:
	var night := w.hour >= 19.0 or w.hour < 5.8
	var want := c.resting and night and c.action == "" and c.health > 0.0
	if want and w.time - c.last_hit_time < 5.0:
		want = false
	if want != sleeping:
		sleeping = want
		if not Net.active:      # online, the host speeds time up only when everyone sleeps
			Engine.time_scale = 7.0 if sleeping else 1.0
		if sleeping:
			message.emit("You sleep through the cold night..." if not Net.active else "You sleep. The night passes quickly once every player rests.")
			if Game.main != null:
				Game.main.autosave()
		elif not night and c.resting:
			c.resting = false


# ------------------------------------------------------------------ events

func modify_damage(amount: float) -> float:
	stats.bitten += 1
	if sleeping:
		sleeping = false
		if not Net.active:
			Engine.time_scale = 1.0
		c.resting = false
	if w.camera != null:
		w.camera.add_shake(clampf(amount / c.max_health * 2.0, 0.2, 1.0))
	return amount


func on_eat(amount: float, what: String) -> void:
	stomach += amount
	stats.eaten += 1 if amount > 0.0 else 0
	# immediate small satiety boost so eating feels rewarding
	food = minf(100.0, food + amount / c.mass * 40.0)
	water = minf(100.0, water + amount / c.mass * 25.0)


func on_drink(_amount: float) -> void:
	water = minf(100.0, water + 9.0)
	body_temp = maxf(body_temp - 0.3, 20.0)


func on_kill(victim: Creature) -> void:
	on_kill_info(victim.sp.name, victim.mass, victim.species_id == "monitor")


func on_kill_info(sp_name: String, mass: float, monitor: bool) -> void:
	stats.kills += 1
	if mass > stats.biggest_kill_mass:
		stats.biggest_kill_mass = mass
		stats.biggest_kill = sp_name
	if monitor:
		stats.fights_won += 1


## Online: what the host saw our lizard do.
func on_net_event(kind: String, sval: String, fval: float, ival: int) -> void:
	match kind:
		"kill":
			on_kill_info(sval, fval, ival == 1)
		"hit":
			_fought[ival] = true
		"rival_fled":
			if _fought.has(ival):
				_fought.erase(ival)
				stats.fights_won += 1
				message.emit("Your rival retreats.")


func on_hit_dealt(victim: Creature, _dmg: float) -> void:
	if victim.species_id == "monitor":
		_fought[victim.id] = true


func notify_rival_fled(o: Creature) -> void:
	if _fought.has(o.id):
		_fought.erase(o.id)
		stats.fights_won += 1
		message.emit("Your rival retreats.")


func on_courted(partner: Creature) -> void:
	if partner == null or not is_instance_valid(partner) or not partner.alive:
		return
	court_cooldown = 120.0
	var accept := c.health_frac() > 0.4 and randf() < 0.8
	if not accept:
		message.emit("The other monitor is not interested.")
		return
	Sfx.play("stage_up", -8.0, 1.3)
	if c.sex == 0:
		gravid = true
		message.emit("You have mated. Find a termite mound and dig a nest (E).")
	else:
		var m: Dictionary = w.terrain.nearest_mound(Vector2(partner.position.x, partner.position.z), 200.0)
		if not m.is_empty():
			var eggs := randi_range(5, 9)
			Net.request_nest(Vector3(m.p.x, w.terrain.height(m.p.x, m.p.y), m.p.y) + Vector3(0.8, 0, 0.8), eggs, lineage + 1)
			stats.offspring += eggs
			message.emit("You have mated. She will lay %d eggs in a termite mound." % eggs)
		if partner.brain != null and partner.brain.has_method("set_state"):
			partner.brain.set_state("wander")


func lay_eggs(m: Dictionary) -> void:
	if not gravid:
		return
	gravid = false
	var eggs := randi_range(6, 10)
	var p := Vector3(m.p.x, w.terrain.height(m.p.x, m.p.y), m.p.y)
	var off := (c.position - p)
	off.y = 0
	p += off.normalized() * m.r * 0.8
	Net.request_nest(p, eggs, lineage + 1)
	stats.offspring += eggs
	Sfx.play_at("egg_crack", p, -2.0, 0.8, 20.0)
	message.emit("You lay %d eggs deep in the warm mound. Your line continues." % eggs)


## Tongue-flick: read the air for food, water and danger.
func taste_air() -> void:
	var t := w.terrain
	var parts: Array = []
	var p := c.position
	# carrion
	var best: Creature = null
	var bd := 110.0
	for carc in w.carcasses:
		var cc: Creature = carc
		if cc.removed or cc.meat < 0.005:
			continue
		var d := p.distance_to(cc.position)
		if d < bd:
			bd = d
			best = cc
	if best != null:
		parts.append("carrion " + _dir_words(best.position))
		w.spawn_scent(best.position, Color(1.0, 0.8, 0.3))
	# live prey of a practical size
	var prey: Creature = null
	var pd := 35.0
	for o in w.query(p, 35.0):
		var oc: Creature = o
		if oc.alive and oc != c and c.can_hunt(oc) and oc.mass > c.mass * 0.03:
			var d2 := p.distance_to(oc.position)
			if d2 < pd:
				pd = d2
				prey = oc
	if prey != null:
		parts.append(prey.sp.name.to_lower() + " " + _dir_words(prey.position))
		w.spawn_scent(prey.position, Color(0.9, 0.9, 0.5))
	# eggs
	if c.mass >= 0.18:
		for m in t.turkey_mounds:
			if m.eggs > 0 and Vector2(p.x, p.z).distance_to(m.p) < 60.0:
				var mp := Vector3(m.p.x, t.height(m.p.x, m.p.y), m.p.y)
				parts.append("eggs " + _dir_words(mp))
				w.spawn_scent(mp, Color(1.0, 0.95, 0.8))
				break
	# water
	if water < 70.0:
		var sh := t.nearest_shore(Vector2(p.x, p.z), 90.0)
		if sh.y > -900.0:
			parts.append("water " + _dir_words(sh))
			w.spawn_scent(sh, Color(0.4, 0.7, 1.0))
	# danger
	var danger: Creature = null
	var dd := 45.0
	for o in w.query(p, 45.0):
		var oc2: Creature = o
		if oc2.alive and oc2 != c and (oc2.can_hunt(c) or (oc2.species_id == "monitor" and oc2.mass > c.mass * 1.8 and oc2.territory > 0.0)):
			var d3 := p.distance_to(oc2.position)
			if d3 < dd:
				dd = d3
				danger = oc2
	if danger != null:
		parts.append("DANGER: " + danger.sp.name.to_lower() + " " + _dir_words(danger.position))
		w.spawn_scent(danger.position, Color(1.0, 0.25, 0.2))
	if parts.is_empty():
		message.emit("You taste the air... nothing of note.")
	else:
		message.emit("You taste: " + ", ".join(parts))


func _dir_words(target: Vector3) -> String:
	var d := target - c.position
	d.y = 0
	var dist := d.length()
	var rel := "close by"
	if dist > 4.0:
		var f := w.camera.flat_forward()
		var ang := wrapf(atan2(d.x, d.z) - atan2(f.x, f.z), -PI, PI)
		var a := absf(ang)
		var where := "ahead"
		if a > 2.4:
			where = "behind you"
		elif a > 0.8:
			where = "to your left" if ang > 0.0 else "to your right"
		var how := "near" if dist < 20.0 else ("some way" if dist < 55.0 else "far")
		rel = how + ", " + where
	return "(" + rel + ")"


# ------------------------------------------------------------------ hints

func _show(id: String, text: String) -> void:
	if hints_seen.has(id) or not Game.settings.hints:
		return
	hints_seen[id] = true
	hint.emit(id, text)


func _check_hints() -> void:
	if age_t > 3.0:
		_show("move", "[W A S D] crawl     [Mouse] look     [Shift] sprint")
	if age_t > 14.0:
		_show("hunger", "You are born hungry. Grasshoppers are easy prey.  [LMB] bite   [E] eat")
	if age_t > 40.0:
		_show("taste", "[F] flick your tongue to taste the air for food, water and danger.")
	if water < 45.0:
		_show("thirst", "You are thirsty. Stand at the water's edge and press [E] to drink.")
	if temp_state == "cold" and age_t > 20.0:
		_show("cold", "You are cold and sluggish. Bask in the sun - rocks warm fastest.")
	if temp_state in ["warm", "hot"]:
		_show("hot", "You are overheating. Find shade under trees, or cool off in water.")
	if c.health_frac() < 0.5:
		_show("hurt", "You are wounded. Hide and rest [R] to recover. Bushes and hollow logs conceal you.")
	if w.is_night() and age_t > 30.0:
		_show("night", "Night falls. Find shelter and rest [R] to sleep until morning.")
	if age_t > 100.0 and stage < 3:
		_show("climb", "Young monitors live in the trees. [E] at a trunk to climb - little can reach you there.")
	if age_t > 70.0:
		_show("stalk", "[C] creep slowly - prey and predators notice you less.   [Space] dodge")
	if stage >= 1:
		_show("juvenile", "You can now break brush-turkey eggs. Their mounds are in the woodland - the turkeys defend them.")
	if stage >= 1 and age_t > 60.0:
		_show("posture", "Other monitors guard territories. [Q] rear up and hiss to intimidate.  [RMB] tail whip.")
	if stage >= 2:
		_show("subadult", "Eagles no longer see you as prey. Carcasses and fish can feed a growing body.")
	if stage >= 3:
		_show("adult", "You are an adult - too heavy for the trees now. Contest territory, and find a mate of the other sex [E] to continue your line.")
	if stage >= 4:
		_show("old", "Old age slows you. Your strength wanes with every day.")
	# danger nearby
	for o in w.query(c.position, 28.0):
		var oc: Creature = o
		if oc.alive and oc.can_hunt(c):
			match oc.species_id:
				"eagle":
					_show("eagle", "An eagle circles overhead! Get under a bush or into a hollow log.")
				"dingo":
					_show("dingo", "Dingoes hunt by scent and speed. Run up a tree [E at a trunk] - they cannot follow.")
				"croc":
					_show("croc", "Something large moves beneath the water...")
				"monitor":
					_show("cannibal", "Big monitors eat small ones. Stay out of their way.")
				"crow":
					_show("crow", "Ravens will peck at hatchlings. Keep moving or hide.")
			break


# ------------------------------------------------------------------ save

func to_dict() -> Dictionary:
	return {
		"mass": c.mass, "health_frac": c.health_frac(), "stamina": c.stamina,
		"food": food, "stomach": stomach, "water": water, "temp": body_temp,
		"age_t": age_t, "adult_t": adult_t, "old_t": old_t, "sex": c.sex,
		"pos": [c.position.x, c.position.y, c.position.z], "yaw": c.yaw,
		"hour": w.hour, "day": w.day, "time": w.time,
		"stats": stats, "gravid": gravid, "lineage": lineage, "hints_seen": hints_seen.keys(),
		"nests": w.nests.map(func(n): return {"p": [n.p.x, n.p.y, n.p.z], "eggs": n.eggs, "t": n.t, "lineage": n.lineage}),
	}


func from_dict(d: Dictionary) -> void:
	food = d.get("food", food)
	stomach = d.get("stomach", 0.0)
	water = d.get("water", water)
	body_temp = d.get("temp", body_temp)
	age_t = d.get("age_t", 0.0)
	adult_t = d.get("adult_t", 0.0)
	old_t = d.get("old_t", 0.0)
	gravid = d.get("gravid", false)
	lineage = int(d.get("lineage", 1))
	var st: Dictionary = d.get("stats", {})
	for k in st.keys():
		stats[k] = st[k]
	for h in d.get("hints_seen", []):
		hints_seen[h] = true
