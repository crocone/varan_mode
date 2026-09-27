class_name Hud
extends CanvasLayer
## Minimal in-game HUD: vitals, body temperature, life stage, contextual
## prompts, hints and transient messages. Screen-space vignettes for pain,
## cold, heat and sleep.

var life: PlayerLife
var player: Creature
var world: World
var root := Control.new()
var bars := {}
var temp_bar: Control
var temp_marker: ColorRect
var temp_label: Label
var stage_label: Label
var growth_bar: ProgressBar
var time_label: Label
var net_label: Label
var zone_label: Label
var prompt_label: Label
var hint_panel: PanelContainer
var hint_label: Label
var msg_label: Label
var banner: Label
var banner_sub: Label
var vignette: ColorRect
var vig_mat: ShaderMaterial
var sleep_rect: ColorRect
var hint_queue: Array = []
var hint_t := 0.0
var msg_t := 0.0
var banner_t := 0.0
var zone_t := 0.0
var last_zone := ""
var pain := 0.0
var last_health := -1.0
var hidden_hud := false

const VIGNETTE_SHADER := """
shader_type canvas_item;
uniform vec4 tint : source_color = vec4(0.0);
uniform float amount = 0.0;
uniform float dark = 0.0;
void fragment() {
	vec2 d = UV - vec2(0.5);
	float v = smoothstep(0.25, 0.75, length(d * vec2(1.2, 1.0)));
	COLOR = vec4(tint.rgb, v * amount + dark);
}
"""


func setup(w: World, p: Creature, l: PlayerLife) -> void:
	world = w
	player = p
	life = l
	layer = 5
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UITheme.theme()
	add_child(root)
	# vignette
	vignette = ColorRect.new()
	vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vig_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = VIGNETTE_SHADER
	vig_mat.shader = sh
	vignette.material = vig_mat
	root.add_child(vignette)
	sleep_rect = ColorRect.new()
	sleep_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	sleep_rect.color = Color(0.02, 0.02, 0.05, 0.0)
	sleep_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(sleep_rect)
	# vitals (bottom-left)
	var vit := VBoxContainer.new()
	vit.anchor_top = 1.0
	vit.anchor_bottom = 1.0
	vit.offset_left = 28
	vit.offset_top = -170
	vit.offset_bottom = -26
	vit.offset_right = 300
	vit.add_theme_constant_override("separation", 5)
	root.add_child(vit)
	bars.health = _bar(vit, "HEALTH", Color(0.78, 0.26, 0.2), 9)
	bars.stamina = _bar(vit, "STAMINA", Color(0.9, 0.85, 0.7), 5)
	bars.food = _bar(vit, "FOOD", Color(0.9, 0.62, 0.22), 7)
	bars.water = _bar(vit, "WATER", Color(0.35, 0.62, 0.9), 7)
	# temperature gauge
	var trow := HBoxContainer.new()
	var tl := UITheme.label("BODY", 12, UITheme.INK_DIM)
	tl.custom_minimum_size.x = 64
	trow.add_child(tl)
	temp_bar = Control.new()
	temp_bar.custom_minimum_size = Vector2(160, 8)
	temp_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var grad := Gradient.new()
	grad.set_color(0, Color(0.3, 0.5, 0.95))
	grad.set_color(1, Color(0.95, 0.3, 0.15))
	grad.add_point(0.45, Color(0.45, 0.8, 0.45))
	grad.add_point(0.72, Color(0.55, 0.85, 0.4))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.width = 128
	gt.height = 4
	var tr := TextureRect.new()
	tr.texture = gt
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.modulate = Color(1, 1, 1, 0.8)
	temp_bar.add_child(tr)
	temp_marker = ColorRect.new()
	temp_marker.color = Color(1, 1, 1)
	temp_marker.size = Vector2(3, 14)
	temp_marker.position = Vector2(0, -3)
	temp_bar.add_child(temp_marker)
	trow.add_child(temp_bar)
	temp_label = UITheme.label("", 13, UITheme.INK)
	temp_label.custom_minimum_size.x = 80
	var spacer := Control.new()
	spacer.custom_minimum_size.x = 8
	trow.add_child(spacer)
	trow.add_child(temp_label)
	vit.add_child(trow)
	# stage (top-left)
	var top := VBoxContainer.new()
	top.offset_left = 28
	top.offset_top = 22
	top.offset_right = 360
	root.add_child(top)
	stage_label = UITheme.label("Hatchling", 26, UITheme.INK, UITheme.title_font())
	top.add_child(stage_label)
	growth_bar = ProgressBar.new()
	growth_bar.custom_minimum_size = Vector2(200, 4)
	growth_bar.show_percentage = false
	growth_bar.max_value = 1.0
	_style_bar(growth_bar, Color(0.85, 0.6, 0.28), 4)
	top.add_child(growth_bar)
	time_label = UITheme.label("", 14, UITheme.INK_DIM)
	top.add_child(time_label)
	net_label = UITheme.label("", 13, UITheme.INK_DIM)
	top.add_child(net_label)
	refresh_players()
	# zone name (top-center fade)
	zone_label = UITheme.label("", 22, UITheme.INK, UITheme.title_font())
	zone_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	zone_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	zone_label.offset_left = -300
	zone_label.offset_right = 300
	zone_label.offset_top = 26
	zone_label.modulate.a = 0.0
	root.add_child(zone_label)
	# prompt (bottom-center)
	prompt_label = UITheme.label("", 20, UITheme.INK)
	prompt_label.anchor_left = 0.5
	prompt_label.anchor_right = 0.5
	prompt_label.anchor_top = 1.0
	prompt_label.anchor_bottom = 1.0
	prompt_label.offset_left = -300
	prompt_label.offset_right = 300
	prompt_label.offset_top = -120
	prompt_label.offset_bottom = -92
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(prompt_label)
	msg_label = UITheme.label("", 17, UITheme.INK)
	msg_label.anchor_left = 0.5
	msg_label.anchor_right = 0.5
	msg_label.anchor_top = 1.0
	msg_label.anchor_bottom = 1.0
	msg_label.offset_left = -420
	msg_label.offset_right = 420
	msg_label.offset_top = -80
	msg_label.offset_bottom = -30
	msg_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(msg_label)
	# hint panel (top-right)
	hint_panel = PanelContainer.new()
	hint_panel.anchor_left = 1.0
	hint_panel.anchor_right = 1.0
	hint_panel.offset_left = -440
	hint_panel.offset_right = -28
	hint_panel.offset_top = 24
	hint_panel.modulate.a = 0.0
	hint_label = UITheme.label("", 17, UITheme.INK)
	hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint_label.custom_minimum_size.x = 360
	hint_panel.add_child(hint_label)
	root.add_child(hint_panel)
	# stage banner
	banner = UITheme.label("", 64, UITheme.INK, UITheme.title_font())
	banner.set_anchors_preset(Control.PRESET_CENTER)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.offset_left = -500
	banner.offset_right = 500
	banner.offset_top = -140
	banner.offset_bottom = -60
	banner.modulate.a = 0.0
	root.add_child(banner)
	banner_sub = UITheme.label("", 20, UITheme.INK_DIM)
	banner_sub.set_anchors_preset(Control.PRESET_CENTER)
	banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner_sub.offset_left = -500
	banner_sub.offset_right = 500
	banner_sub.offset_top = -56
	banner_sub.offset_bottom = -20
	banner_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	banner_sub.modulate.a = 0.0
	root.add_child(banner_sub)
	life.hint.connect(_on_hint)
	life.message.connect(show_message)
	life.stage_changed.connect(_on_stage)


func _bar(parent: Control, label_text: String, col: Color, h: int) -> ProgressBar:
	var row := HBoxContainer.new()
	var l := UITheme.label(label_text, 12, UITheme.INK_DIM)
	l.custom_minimum_size.x = 64
	row.add_child(l)
	var b := ProgressBar.new()
	b.custom_minimum_size = Vector2(160, h)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.show_percentage = false
	b.max_value = 1.0
	_style_bar(b, col, h)
	row.add_child(b)
	parent.add_child(row)
	return b


func _style_bar(b: ProgressBar, col: Color, h: int) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.35)
	bg.content_margin_top = h * 0.5
	bg.content_margin_bottom = h * 0.5
	var fg := StyleBoxFlat.new()
	fg.bg_color = col
	b.add_theme_stylebox_override("background", bg)
	b.add_theme_stylebox_override("fill", fg)


func refresh_players() -> void:
	if net_label == null:
		return
	if not Net.active:
		net_label.text = ""
		return
	var names: Array = []
	for id in Net.players.keys():
		names.append(Net.players[id].name)
	net_label.text = ("Hosting" if Net.is_host else "Online") + " · " + ", ".join(names)


func show_message(text: String) -> void:
	msg_label.text = text
	msg_t = 5.0 + text.length() * 0.03


func _on_hint(_id: String, text: String) -> void:
	hint_queue.append(text)


func _on_stage(s: int) -> void:
	banner.text = PlayerLife.STAGES[s].to_upper()
	var subs := [
		"",
		"Bigger now. New prey is within reach - and new rivals notice you.",
		"The sky is safer. The ground is not.",
		"Few animals here can match you. Other adults will test that.",
		"Your body is failing. Live well what remains.",
	]
	banner_sub.text = subs[s]
	banner_t = 6.0
	Sfx.play("stage_up", -2.0)


func _process(delta: float) -> void:
	if player == null or life == null:
		return
	var dt := delta / maxf(Engine.time_scale, 0.001)
	root.visible = not hidden_hud
	var hf := player.health_frac()
	bars.health.value = hf
	bars.stamina.value = player.stamina
	bars.stamina.modulate = Color(1, 0.5, 0.4) if player.exhausted else Color(1, 1, 1)
	bars.food.value = life.food / 100.0
	bars.water.value = life.water / 100.0
	var tf := clampf((life.body_temp - 14.0) / (44.0 - 14.0), 0.0, 1.0)
	temp_marker.position.x = tf * temp_bar.size.x - 1.5
	var tnames := {"cold": "Cold", "cool": "Cool", "ok": "", "warm": "Warm", "hot": "Overheating"}
	temp_label.text = tnames[life.temp_state]
	temp_label.add_theme_color_override("font_color", Color(0.55, 0.7, 1.0) if life.temp_state in ["cold", "cool"] else Color(1.0, 0.55, 0.35))
	stage_label.text = life.stage_name() + ("  ·  gravid" if life.gravid else "")
	growth_bar.value = life.growth_progress()
	var hh := int(world.hour)
	var mm := int((world.hour - hh) * 60.0)
	var sexs := "♀" if player.sex == 0 else "♂"
	time_label.text = "Day %d   %02d:%02d   %s   %.2f kg" % [world.day, hh, mm, sexs, player.mass]
	# prompt
	var pc = player.brain
	var ptxt := ""
	if pc != null and pc.get("interact_hint") != null and pc.interact_hint != "":
		ptxt = ("[E] " if pc.interact_kind != "" else "") + pc.interact_hint
	if player.sheltered:
		ptxt += ("\n" if ptxt != "" else "") + "Hidden"
	elif player.cover > 0.5:
		ptxt += ("\n" if ptxt != "" else "") + "Concealed"
	if life.sleeping:
		ptxt = "Sleeping..."
	prompt_label.text = ptxt
	# messages
	if msg_t > 0.0:
		msg_t -= dt
		msg_label.modulate.a = clampf(msg_t, 0.0, 1.0)
	# hints
	if hint_t > 0.0:
		hint_t -= dt
		hint_panel.modulate.a = clampf(minf(hint_t, 9.0 - hint_t) * 2.0, 0.0, 1.0)
	elif not hint_queue.is_empty():
		hint_label.text = hint_queue.pop_front()
		hint_t = 9.0
	else:
		hint_panel.modulate.a = 0.0
	# banner
	if banner_t > 0.0:
		banner_t -= dt
		var a := clampf(minf(banner_t, 6.0 - banner_t), 0.0, 1.0)
		banner.modulate.a = a
		banner_sub.modulate.a = a
	# zone title when entering a new area
	zone_t -= dt
	if zone_t <= 0.0:
		zone_t = 1.0
		var z := world.terrain.zone_name(player.position.x, player.position.z)
		if z != last_zone:
			last_zone = z
			zone_label.text = z
			var tw := create_tween()
			tw.tween_property(zone_label, "modulate:a", 0.9, 1.0)
			tw.tween_interval(2.5)
			tw.tween_property(zone_label, "modulate:a", 0.0, 1.5)
	# vignettes
	if last_health >= 0.0 and player.health < last_health - 0.0001:
		pain = minf(1.0, pain + (last_health - player.health) / player.max_health * 3.0 + 0.25)
	last_health = player.health
	pain = maxf(0.0, pain - dt * 1.2)
	var tint := Color(0.6, 0.05, 0.02)
	var amt := pain * 0.8 + (1.0 - hf) * 0.35
	if life.temp_state == "cold":
		tint = tint.lerp(Color(0.2, 0.35, 0.7), 0.7 if pain < 0.1 else 0.0)
		amt = maxf(amt, 0.35)
	elif life.temp_state == "hot":
		tint = tint.lerp(Color(0.9, 0.45, 0.1), 0.7 if pain < 0.1 else 0.0)
		amt = maxf(amt, 0.4 + sin(Time.get_ticks_msec() * 0.004) * 0.1)
	vig_mat.set_shader_parameter("tint", tint)
	vig_mat.set_shader_parameter("amount", clampf(amt, 0.0, 0.9))
	var sa := 0.55 if life.sleeping else 0.0
	sleep_rect.color.a = move_toward(sleep_rect.color.a, sa, dt * 0.8)
