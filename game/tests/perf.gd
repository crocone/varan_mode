extends Node
## GPU cost breakdown in a woodland view.
func run(main) -> void:
	var world = main.world
	var vp := get_viewport()
	RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
	world.hour = 11.0
	world.camera.mode = "manual"
	var spots := [Vector3(-95, 0, 60), Vector3(-40, 0, 88), Vector3(10, 0, 40)]
	var statics: Node = world.get_node("Static")
	for sp in spots:
		var p: Vector3 = sp
		p.y = world.terrain.height(p.x, p.z) + 1.2
		world.camera.cam.global_transform = Transform3D(Basis.looking_at(Vector3(1, -0.15, 0.4), Vector3.UP), p)
		for mode in ["all", "no_shadows", "none_static"]:
			for ch in statics.get_children():
				if ch is GeometryInstance3D:
					ch.visible = true
			world.sun.shadow_enabled = true
			world.env.ssao_enabled = Game.settings.quality >= 2
			match mode:
				"no_leaves":
					for ch in statics.get_children():
						if ch is MultiMeshInstance3D and ch.multimesh.mesh.get_surface_count() > 1:
							ch.visible = false
				"no_grass":
					for ch in statics.get_children():
						if ch is MultiMeshInstance3D and ch.visibility_range_end > 0.0 and ch.visibility_range_end < 120.0:
							ch.visible = false
				"no_shadows":
					world.sun.shadow_enabled = false
				"no_ssao":
					world.env.ssao_enabled = false
				"none_static":
					for ch in statics.get_children():
						if ch is MultiMeshInstance3D:
							ch.visible = false
			var acc := 0.0
			var acc_cpu := 0.0
			var acc_setup := 0.0
			var acc_proc := 0.0
			var t0 := 0
			for k in 40:
				await RenderingServer.frame_post_draw
				if k == 10:
					t0 = Time.get_ticks_usec()
				if k >= 10:
					acc += RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())
					acc_cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp.get_viewport_rid())
					acc_setup += RenderingServer.get_frame_setup_time_cpu()
					acc_proc += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			var frame_ms := (Time.get_ticks_usec() - t0) / 29000.0
			print("spot ", sp, " ", mode, " frame ", snappedf(frame_ms, 0.1), " gpu ", snappedf(acc / 30.0, 0.01), " rcpu ", snappedf(acc_cpu / 30.0, 0.01), " setup ", snappedf(acc_setup / 30.0, 0.01), " process ", snappedf(acc_proc / 30.0, 0.01))
	get_tree().quit()
