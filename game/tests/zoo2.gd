extends Node
## Close-up portraits of each species at rest and while moving.
var main
var world
func run(m) -> void:
	main = m
	world = m.world
	var shots_dir := ProjectSettings.globalize_path("res://").path_join("../tools/shots/")
	world.hour = 9.5
	main.start_new_life()
	for i in 100:
		if main.state == "playing":
			break
		await get_tree().create_timer(0.2).timeout
	var p: Creature = world.player
	p.invulnerable = true
	p.brain.enabled = false
	p.position = Vector3(-43, world.terrain.height(-43, 86), 86)
	var list: Array = Game.cmd_args.slice(1) if Game.cmd_args.size() > 1 else ["dingo", "wallaby", "mouse", "turkey", "crow", "eagle", "frog", "grasshopper", "skink"]
	for sp_id in list:
		var pos := Vector2(-40, 90)
		var c: Creature = world.spawn(sp_id, Species.DEFS[sp_id].ref_mass, pos, 0.3)
		c.brain = null
		c.invulnerable = true
		var L := c.length
		for k in 20:
			await get_tree().process_frame
		for v in [["side", Vector3(1.0, 0.25, 0.1)], ["front", Vector3(0.6, 0.3, 1.0)]]:
			var d: Vector3 = (v[1] as Vector3).normalized().rotated(Vector3.UP, 0.3)
			var tgt := c.position + Vector3(0, L * 0.3, 0)
			var cp := tgt + d * L * 1.7
			world.camera.mode = "manual"
			world.camera.cam.global_transform = Transform3D(Basis.looking_at(tgt - cp, Vector3.UP), cp)
			world.camera.cam.near = 0.005
			for k in 3:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(shots_dir + "zoo2_%s_%s.png" % [sp_id, v[0]])
		world.remove_creature(c)
	get_tree().quit()
