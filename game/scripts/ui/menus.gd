class_name Menus
extends CanvasLayer
## Main menu, pause menu, settings and the end-of-life screen.

signal new_life
signal continue_life
signal continue_lineage
signal resume
signal save_now
signal to_menu
signal unstuck
signal host_game(continue_saved: bool)
signal join_game(address: String, port: int)
signal host_now

var root := Control.new()
var main_panel: Control
var pause_panel: Control
var settings_panel: Control
var death_panel: Control
var loading_panel: Control
var continue_btn: Button
var death_title: Label
var death_cause: Label
var death_stats: Label
var lineage_btn: Button
var save_status: Label
var _settings_back: Callable
var loading_label: Label
var mp_panel: Control
var mp_status: Label
var mp_name: LineEdit
var mp_address: LineEdit
var mp_port: LineEdit
var mp_host_continue: Button
var mp_join_note: Label
var pause_save_btn: Button
var pause_menu_btn: Button
var pause_host_btn: Button
var pause_quit_btn: Button
var pause_players: Label
var death_menu_btn: Button
var death_new_btn: Button


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = UITheme.theme()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_build_loading()
	_build_main()
	_build_pause()
	_build_settings()
	_build_death()
	_build_multiplayer()
	show_only(loading_panel)


func show_only(p: Control) -> void:
	for c in [main_panel, pause_panel, settings_panel, death_panel, loading_panel, mp_panel]:
		c.visible = c == p
	if p != null and p != death_panel:
		var b := _first_button(p)
		if b != null:
			b.grab_focus.call_deferred()


func hide_all() -> void:
	show_only(null)


func _first_button(n: Node) -> Button:
	for ch in n.get_children():
		if ch is Button and ch.visible and not ch.disabled:
			return ch
		var r := _first_button(ch)
		if r != null:
			return r
	return null


func _btn(parent: Control, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.pressed.connect(func():
		Sfx.ui("ui_click")
		cb.call())
	b.mouse_entered.connect(func(): Sfx.ui("ui_hover"))
	parent.add_child(b)
	return b


func _logo(parent: Control, big := true) -> void:
	var t := UITheme.label("VaranMod", 96 if big else 54, UITheme.INK, UITheme.title_font())
	t.add_theme_constant_override("outline_size", 0)
	t.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	t.add_theme_constant_override("shadow_offset_x", 3)
	t.add_theme_constant_override("shadow_offset_y", 3)
	parent.add_child(t)
	var line := ColorRect.new()
	line.color = UITheme.OCHRE
	line.custom_minimum_size = Vector2(420 if big else 240, 3)
	line.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	parent.add_child(line)
	if big:
		var sub := UITheme.label("a life, from egg to old age", 22, UITheme.INK_DIM, UITheme.title_font())
		parent.add_child(sub)


func _side_backdrop(parent: Control) -> void:
	var g := Gradient.new()
	g.set_color(0, Color(0.05, 0.035, 0.025, 0.85))
	g.set_color(1, Color(0.05, 0.035, 0.025, 0.0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0)
	var tr := TextureRect.new()
	tr.texture = gt
	tr.anchor_bottom = 1.0
	tr.offset_right = 760
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(tr)


func _build_loading() -> void:
	loading_panel = Control.new()
	loading_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.045, 0.035)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	loading_panel.add_child(bg)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_CENTER)
	v.offset_left = -300
	v.offset_right = 300
	v.offset_top = -90
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	loading_panel.add_child(v)
	var t := UITheme.label("VaranMod", 72, UITheme.INK, UITheme.title_font())
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	loading_label = UITheme.label("The sun rises over the riverland...", 20, UITheme.INK_DIM)
	loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(loading_label)
	root.add_child(loading_panel)


func _build_main() -> void:
	main_panel = Control.new()
	main_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_side_backdrop(main_panel)
	var v := VBoxContainer.new()
	v.offset_left = 90
	v.offset_top = 120
	v.offset_right = 700
	v.add_theme_constant_override("separation", 10)
	main_panel.add_child(v)
	_logo(v)
	var sp := Control.new()
	sp.custom_minimum_size.y = 50
	v.add_child(sp)
	continue_btn = _btn(v, "Continue", func(): continue_life.emit())
	_btn(v, "New Life", func(): new_life.emit())
	_btn(v, "Multiplayer", func(): open_multiplayer())
	_btn(v, "Settings", func(): open_settings(func(): show_only(main_panel)))
	_btn(v, "Quit", func(): get_tree().quit())
	var ver := UITheme.label("beta " + Game.VERSION + "   ·   WASD move · Mouse look · LMB bite · E eat/drink · F taste the air", 14, UITheme.INK_DIM)
	ver.anchor_top = 1.0
	ver.anchor_bottom = 1.0
	ver.offset_left = 90
	ver.offset_top = -50
	ver.offset_right = 1200
	main_panel.add_child(ver)
	root.add_child(main_panel)


func refresh_main() -> void:
	continue_btn.visible = Game.has_save()


func _build_pause() -> void:
	pause_panel = Control.new()
	pause_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.02, 0.015, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_panel.add_child(dim)
	_side_backdrop(pause_panel)
	var v := VBoxContainer.new()
	v.offset_left = 90
	v.offset_top = 140
	v.offset_right = 600
	v.add_theme_constant_override("separation", 8)
	pause_panel.add_child(v)
	_logo(v, false)
	var sp := Control.new()
	sp.custom_minimum_size.y = 30
	v.add_child(sp)
	_btn(v, "Resume", func(): resume.emit())
	pause_save_btn = _btn(v, "Save", func(): save_now.emit())
	pause_host_btn = _btn(v, "Open to other players", func(): host_now.emit())
	_btn(v, "Settings", func(): open_settings(func(): show_only(pause_panel)))
	_btn(v, "I'm stuck", func(): unstuck.emit())
	pause_menu_btn = _btn(v, "Save & Main Menu", func(): to_menu.emit())
	pause_quit_btn = _btn(v, "Quit Game", func():
		save_now.emit()
		get_tree().quit())
	save_status = UITheme.label("", 16, UITheme.INK_DIM)
	v.add_child(save_status)
	pause_players = UITheme.label("", 16, UITheme.INK_DIM)
	v.add_child(pause_players)
	var ctl := UITheme.label(
		"W A S D  move        Shift  sprint        C / Ctrl  creep\n" +
		"LMB  bite        RMB  tail whip        Space  dodge        Q (hold)  posture & hiss\n" +
		"E  eat / drink / interact        F  taste the air        R  rest / sleep        H  hide HUD", 15, UITheme.INK_DIM)
	ctl.anchor_top = 1.0
	ctl.anchor_bottom = 1.0
	ctl.offset_left = 90
	ctl.offset_top = -110
	ctl.offset_right = 1200
	pause_panel.add_child(ctl)
	root.add_child(pause_panel)


func _row(parent: Control, text: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	var l := UITheme.label(text, 18)
	l.custom_minimum_size.x = 220
	h.add_child(l)
	parent.add_child(h)
	return h


func _slider(parent: Control, text: String, key: String, mn: float, mx: float, step: float) -> void:
	var h := _row(parent, text)
	var s := HSlider.new()
	s.min_value = mn
	s.max_value = mx
	s.step = step
	s.custom_minimum_size = Vector2(260, 24)
	s.value = Game.settings[key]
	s.value_changed.connect(func(v): Game.set_setting(key, v))
	h.add_child(s)


func _toggle(parent: Control, text: String, key: String) -> void:
	var h := _row(parent, text)
	var cb := CheckButton.new()
	cb.button_pressed = Game.settings[key]
	cb.toggled.connect(func(v):
		Sfx.ui("ui_click")
		Game.set_setting(key, v))
	h.add_child(cb)


func _build_settings() -> void:
	settings_panel = Control.new()
	settings_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.02, 0.015, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_panel.add_child(dim)
	var pc := PanelContainer.new()
	pc.set_anchors_preset(Control.PRESET_CENTER)
	pc.offset_left = -330
	pc.offset_right = 330
	pc.offset_top = -300
	pc.offset_bottom = 300
	settings_panel.add_child(pc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	pc.add_child(v)
	v.add_child(UITheme.label("Settings", 34, UITheme.INK, UITheme.title_font()))
	_slider(v, "Master volume", "master_volume", 0.0, 1.0, 0.05)
	_slider(v, "Effects volume", "sfx_volume", 0.0, 1.0, 0.05)
	_slider(v, "Ambience volume", "ambience_volume", 0.0, 1.0, 0.05)
	_slider(v, "Music volume", "music_volume", 0.0, 1.0, 0.05)
	_slider(v, "Mouse sensitivity", "mouse_sensitivity", 0.2, 3.0, 0.05)
	_slider(v, "Field of view", "fov", 55.0, 95.0, 1.0)
	_toggle(v, "Invert mouse Y", "invert_y")
	_toggle(v, "Fullscreen", "fullscreen")
	_toggle(v, "V-Sync", "vsync")
	_toggle(v, "Show hints", "hints")
	var h := _row(v, "Graphics quality")
	var ob := OptionButton.new()
	ob.add_item("Low")
	ob.add_item("Medium")
	ob.add_item("High")
	ob.selected = Game.settings.quality
	ob.item_selected.connect(func(i):
		Game.set_setting("quality", i)
		if Game.world != null:
			Game.world.apply_quality(i))
	h.add_child(ob)
	var note := UITheme.label("Grass density changes apply to the next session.", 13, UITheme.INK_DIM)
	v.add_child(note)
	_btn(v, "Back", func(): _settings_back.call())
	root.add_child(settings_panel)


func open_settings(back: Callable) -> void:
	_settings_back = back
	show_only(settings_panel)


func _build_death() -> void:
	death_panel = Control.new()
	death_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.015, 0.01, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	death_panel.add_child(dim)
	_side_backdrop(death_panel)
	var v := VBoxContainer.new()
	v.offset_left = 90
	v.offset_top = 140
	v.offset_right = 760
	v.add_theme_constant_override("separation", 8)
	death_panel.add_child(v)
	death_title = UITheme.label("Your life has ended", 54, UITheme.INK, UITheme.title_font())
	v.add_child(death_title)
	var line := ColorRect.new()
	line.color = UITheme.RUST
	line.custom_minimum_size = Vector2(300, 3)
	line.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	v.add_child(line)
	death_cause = UITheme.label("", 24, UITheme.INK_DIM, UITheme.title_font())
	v.add_child(death_cause)
	death_stats = UITheme.label("", 18, UITheme.INK)
	v.add_child(death_stats)
	var sp := Control.new()
	sp.custom_minimum_size.y = 24
	v.add_child(sp)
	lineage_btn = _btn(v, "Continue as your offspring", func(): continue_lineage.emit())
	death_new_btn = _btn(v, "New Life", func(): new_life.emit())
	death_menu_btn = _btn(v, "Main Menu", func(): to_menu.emit())
	root.add_child(death_panel)


func show_death(cause: String, life: PlayerLife, has_lineage: bool) -> void:
	var st: Dictionary = life.stats
	var lines := {
		"Old age": "You died of old age, having lived a full life.",
		"Starvation": "You starved.",
		"Thirst": "You died of thirst.",
		"Heatstroke": "The sun was too much. You died of heatstroke.",
	}
	var ctext: String = lines.get(cause, "Killed by a " + cause.to_lower() + ".")
	if cause == "Lace Monitor":
		ctext = "Killed by another monitor."
	elif cause.begins_with("@"):
		ctext = "Killed by " + cause.substr(1) + "."
	death_title.text = "Your life has ended" if cause != "Old age" else "A long life"
	death_cause.text = ctext
	var mins := int(life.age_t / 60.0)
	death_stats.text = "Reached:  %s\nLived until:  day %d  (%d min)\nLargest size:  %.2f kg\nMeals:  %d      Kills:  %d      Rivals bested:  %d\nBiggest kill:  %s\nDistance travelled:  %d m\nOffspring:  %d%s" % [
		life.stage_name(), st.days, mins, st.max_mass, st.eaten, st.kills, st.fights_won,
		st.biggest_kill if st.biggest_kill != "" else "-", int(st.distance), st.offspring,
		("\nGeneration:  %d" % life.lineage) if life.lineage > 1 else ""]
	lineage_btn.visible = has_lineage
	death_new_btn.text = "Hatch again" if Net.active else "New Life"
	death_menu_btn.text = ("End session" if Net.is_host else "Leave the world") if Net.active else "Main Menu"
	show_only(death_panel)


func set_loading(text: String) -> void:
	loading_label.text = text


# ------------------------------------------------------------------ multiplayer

func _field(parent: Control, text: String, value: String, width := 300) -> LineEdit:
	var h := _row(parent, text)
	var e := LineEdit.new()
	e.text = value
	e.custom_minimum_size = Vector2(width, 34)
	e.add_theme_font_size_override("font_size", 18)
	h.add_child(e)
	return e


func _build_multiplayer() -> void:
	mp_panel = Control.new()
	mp_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	mp_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_side_backdrop(mp_panel)
	var v := VBoxContainer.new()
	v.offset_left = 90
	v.offset_top = 120
	v.offset_right = 760
	v.add_theme_constant_override("separation", 10)
	mp_panel.add_child(v)
	_logo(v, false)
	v.add_child(UITheme.label("Multiplayer", 34, UITheme.INK, UITheme.title_font()))
	v.add_child(UITheme.label("Share one living riverland: the host's world, day and animals.\nEach player lives their own monitor's life - rivals, hunters or companions.", 16, UITheme.INK_DIM))
	mp_name = _field(v, "Your name", Game.player_name(), 260)
	mp_name.max_length = 20
	mp_name.text_changed.connect(func(t): Game.settings.player_name = t)
	mp_name.text_submitted.connect(func(_t): Game.save_settings())
	var sp := Control.new()
	sp.custom_minimum_size.y = 8
	v.add_child(sp)
	v.add_child(UITheme.label("Host", 22, UITheme.OCHRE, UITheme.title_font()))
	mp_port = _field(v, "Port (UDP)", str(int(Game.settings.get("net_port", Net.PORT))), 120)
	_btn(v, "Host - hatch a new life", func(): _host(false))
	mp_host_continue = _btn(v, "Host - continue your saved life", func(): _host(true))
	var sp2 := Control.new()
	sp2.custom_minimum_size.y = 8
	v.add_child(sp2)
	v.add_child(UITheme.label("Join", 22, UITheme.OCHRE, UITheme.title_font()))
	mp_address = _field(v, "Host address", str(Game.settings.get("net_address", "127.0.0.1")), 300)
	mp_address.text_submitted.connect(func(_t): _join())
	_btn(v, "Join", func(): _join())
	mp_join_note = UITheme.label("", 14, UITheme.INK_DIM)
	v.add_child(mp_join_note)
	mp_status = UITheme.label("", 17, UITheme.INK)
	mp_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mp_status.custom_minimum_size.x = 620
	v.add_child(mp_status)
	_btn(v, "Back", func():
		if Net.active or Net._peer != null:
			Net.leave()
		show_only(main_panel))
	var tip := UITheme.label("Same network: join the host's local IP (e.g. 192.168.x.x). Over the internet the host must forward UDP port %d, or use a LAN tunnel (ZeroTier, Radmin VPN, Tailscale)." % Net.PORT, 14, UITheme.INK_DIM)
	tip.anchor_top = 1.0
	tip.anchor_bottom = 1.0
	tip.offset_left = 90
	tip.offset_top = -60
	tip.offset_right = 1400
	mp_panel.add_child(tip)
	root.add_child(mp_panel)


func open_multiplayer() -> void:
	mp_name.text = Game.player_name()
	mp_host_continue.visible = Game.has_save(Game.SAVE_PATH)
	mp_join_note.text = "Joining brings your online lizard back." if Game.has_save(Game.NET_SAVE_PATH) else "Joining hatches a new lizard in the host's world."
	show_only(mp_panel)


func _commit_fields() -> void:
	Game.settings.player_name = mp_name.text.strip_edges()
	var port := int(mp_port.text) if mp_port.text.is_valid_int() else Net.PORT
	Game.settings.net_port = clampi(port, 1024, 65535)
	Game.settings.net_address = mp_address.text.strip_edges()
	Game.save_settings()


func _host(cont: bool) -> void:
	_commit_fields()
	host_game.emit(cont)


func _join() -> void:
	_commit_fields()
	var addr: String = Game.settings.net_address
	var port: int = Game.settings.net_port
	# "ip:port" also works
	if addr.count(":") == 1:
		var parts := addr.split(":")
		addr = parts[0]
		if parts[1].is_valid_int():
			port = int(parts[1])
	if addr == "":
		set_net_status("Enter the host's address.")
		return
	join_game.emit(addr, port)


func set_net_status(t: String) -> void:
	if mp_status != null:
		mp_status.text = t


func refresh_pause() -> void:
	var online := Net.active
	pause_save_btn.visible = true
	pause_host_btn.visible = not online
	pause_menu_btn.text = ("Save & end session" if Net.is_host else "Save & leave the world") if online else "Save & Main Menu"
	if online:
		var names: Array = []
		for id in Net.players.keys():
			names.append(Net.players[id].name + (" (host)" if id == 1 else ""))
		pause_players.text = "Online:  " + ",  ".join(names)
		if Net.is_host:
			pause_players.text += "\nWorld open on UDP port %d. The world keeps running while this menu is open." % int(Game.settings.get("net_port", Net.PORT))
		else:
			pause_players.text += "\nThe world keeps running while this menu is open."
	else:
		pause_players.text = ""
