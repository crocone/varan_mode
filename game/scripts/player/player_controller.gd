class_name PlayerController
extends RefCounted
## Translates keyboard/mouse into the player's lizard intentions. Movement is
## camera-relative; the body turns and accelerates like an animal, not a capsule.

var c: Creature
var w: World
var look_point = null
var tongue_now := false
var enabled := true
var interact_hint := ""
var interact_target = null      # what E would act on
var interact_kind := ""
var _posture_held := false


func _init(creature: Creature) -> void:
	c = creature
	w = creature.world


func update(dt: float) -> void:
	if not enabled or not c.alive:
		c.halt()
		return
	var cam := w.camera
	var input := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_forward") - Input.get_action_strength("move_back"))
	var f := cam.flat_forward()
	var r := Vector3(-f.z, 0, f.x)
	var dir := f * input.y + r * input.x
	if c.climbing:
		_update_climbing(input)
		return
	c.stalking = Input.is_action_pressed("stalk")
	c.sprinting = Input.is_action_pressed("sprint") and not c.stalking
	var spd := c.walk_speed()
	if c.sprinting and not c.exhausted:
		spd = c.run_speed()
	elif c.stalking:
		spd = c.walk_speed() * 0.45
	if c.swimming:
		spd *= c.sp.get("swim_mult", 0.75)
	if dir.length_squared() > 0.01:
		c.steer(dir, spd)
		if c.resting:
			c.resting = false
		if c.action == "eat" or c.action == "drink":
			c.cancel_action()
	else:
		c.halt()
	# posture
	c.posturing = Input.is_action_pressed("posture") and c.stamina > 0.05 and not c.swimming
	# rest toggle is handled in _unhandled via main (hold R); here: resting while R held
	if Input.is_action_just_pressed("rest"):
		c.resting = not c.resting
	if c.resting and (dir.length_squared() > 0.01 or c.flinch > 0.0):
		c.resting = false
	# actions
	if Input.is_action_just_pressed("attack"):
		c.try_bite()
	if Input.is_action_just_pressed("tail_whip"):
		c.try_whip()
	if Input.is_action_just_pressed("dodge"):
		c.try_dodge(dir if dir.length_squared() > 0.01 else -c.fwd())
	if Input.is_action_just_pressed("taste"):
		tongue_now = true
		if w.player_life != null:
			w.player_life.taste_air()
	_scan_interact()
	if Input.is_action_just_pressed("interact"):
		_do_interact()
	# head follows the camera a little when idle
	if c.speed < 0.1 and c.action == "":
		look_point = c.position + cam.flat_forward() * 5.0
	else:
		look_point = null


func _update_climbing(input: Vector2) -> void:
	c.sprinting = Input.is_action_pressed("sprint")
	c.climb_in = Vector2(-input.x, input.y)
	c.posturing = false
	if Input.is_action_just_pressed("rest"):
		c.resting = not c.resting
	if input.length_squared() > 0.01:
		c.resting = false
	if Input.is_action_just_pressed("taste"):
		tongue_now = true
		if w.player_life != null:
			w.player_life.taste_air()
	interact_kind = "descend"
	interact_hint = "Climb down   [W/S] up/down  [A/D] around  [Space] jump off"
	if c.climb_h >= c.climb_top() - 0.01:
		interact_hint = "As high as you can go.  [E] climb down   [Space] jump off"
	if Input.is_action_just_pressed("interact"):
		c.stop_climb()
	elif Input.is_action_just_pressed("dodge"):
		c.stop_climb(true)
	look_point = null


func _scan_interact() -> void:
	interact_hint = ""
	interact_target = null
	interact_kind = ""
	var hp := c.head_pos()
	var reach := c.reach() + 0.25 + c.length * 0.15
	# carcass / dead prey
	var best: Creature = null
	var bd := 1e9
	for o in w.query(hp, reach + 2.0):
		var oc: Creature = o
		if oc == c or oc.alive or oc.meat <= 0.0 or oc.carried_by != null:
			continue
		var d := hp.distance_to(oc.position) - oc.length * 0.4
		if d < reach and d < bd:
			bd = d
			best = oc
	if best != null:
		interact_target = best
		interact_kind = "eat"
		interact_hint = "Eat " + best.sp.name.to_lower() + (" carcass" if best.mass > c.mass * 0.5 else "")
		return
	# brush-turkey mound eggs
	for m in w.terrain.turkey_mounds:
		var d2 := Vector2(hp.x, hp.z).distance_to(m.p)
		if d2 < m.r + reach + 0.3:
			if m.eggs > 0:
				if c.mass >= 0.18:
					interact_target = m
					interact_kind = "dig"
					interact_hint = "Dig for eggs"
				else:
					interact_hint = "Too small to dig out eggs"
			return
	# monitor nests at termite mounds (lay eggs)
	if w.player_life != null and w.player_life.gravid:
		var tm: Dictionary = w.terrain.nearest_mound(Vector2(hp.x, hp.z), reach + 0.6)
		if not tm.is_empty():
			interact_target = tm
			interact_kind = "lay"
			interact_hint = "Dig a nest and lay eggs"
			return
	# courtship
	if w.player_life != null and w.player_life.can_court():
		for o in w.query(hp, 3.0 + c.length):
			var oc2: Creature = o
			if oc2 != c and oc2.alive and oc2.species_id == "monitor" and oc2.mass > 5.0 and oc2.sex != c.sex:
				interact_target = oc2
				interact_kind = "court"
				interact_hint = "Court"
				return
	# climbable tree trunk
	var tr: Dictionary = w.terrain.tree_near(Vector2(hp.x, hp.z), reach + 0.25 + c.length * 0.2)
	if not tr.is_empty():
		if c.can_climb():
			interact_target = tr
			interact_kind = "climb"
			interact_hint = "Climb tree"
			return
		elif c.species_id == "monitor" and c.mass >= 6.0:
			interact_hint = "Too heavy to climb now"
	# water: anything wet just in front of the snout, or standing in the shallows
	if not c.swimming:
		for dist in [reach * 0.6, reach + c.length * 0.25 + 0.08]:
			var probe: Vector3 = hp + c.fwd() * dist
			if w.terrain.water_depth(probe.x, probe.z) > 0.005:
				interact_kind = "drink"
				interact_hint = "Drink"
				return
		if w.terrain.water_depth(c.position.x, c.position.z) > -0.01:
			interact_kind = "drink"
			interact_hint = "Drink"
			return
	if c.swimming and w.terrain.water_depth(c.position.x, c.position.z) < c.length * 0.4:
		interact_kind = "drink"
		interact_hint = "Drink"


func _do_interact() -> void:
	match interact_kind:
		"eat":
			c.start_eat(interact_target)
		"dig":
			c.start_eat(interact_target)
		"drink":
			c.start_drink()
		"lay":
			if w.player_life != null:
				w.player_life.lay_eggs(interact_target)
		"court":
			c.start_court(interact_target)
		"climb":
			c.start_climb(interact_target)
