extends Node
## Zoo test: every species in a row, animated in place, close-up screenshots.
var main
var world
var shots_dir := ""
func run(m) -> void:
	main = m
	world = m.world
	shots_dir = ProjectSettings.globalize_path("res://").path_join("../tools/shots/")
	world.hour = 10.0
	main.start_new_life()
	for i in 100:
		if main.state == "playing":
			break
		await get_tree().create_timer(0.2).timeout
	var p: Creature = world.player
	p.invulnerable = true
	p.brain.enabled = false
	var base := Vector2(-40, 90)
	var list := ["dingo", "wallaby", "mouse", "turkey", "crow", "eagle", "frog", "grasshopper", "fish", "croc", "skink", "monitor"]
	for sp_id in list:
		var pos := base
		if sp_id in ["fish", "croc"]:
			pos = world.terrain.random_water_point(Terrain.POND_POS, 8.0, 1.0)
		var c: Creature = world.spawn(sp_id, Species.DEFS[sp_id].ref_mass, pos, 0.0)
		c.brain = null
		c.invulnerable = true
		if sp_id in ["crow", "eagle"]:
			c.flying = true
			c.fly_alt = 2.0
			c.position.y += 2.0
		var L := c.length
		for phase in ["walk", "run"]:
			var spd := c.walk_speed() if phase == "walk" else c.run_speed()
			for k in 30:
				c.steer(Vector3(0, 0, 1), spd)
				await get_tree().process_frame
			var cp := c.position + Vector3(L * 1.6 + 0.3, L * 0.5 + 0.1, L * 0.3)
			world.camera.mode = "manual"
			world.camera.cam.global_transform = Transform3D(Basis.looking_at(c.position + Vector3(0, L * 0.25, 0) - cp, Vector3.UP), cp)
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(shots_dir + "zoo_%s_%s.png" % [sp_id, phase])
		c.halt()
		world.remove_creature(c)
		print("zoo ", sp_id, " skinned=", c.part_skin != null or (c.rig.get("skinned") == true))
	get_tree().quit()
