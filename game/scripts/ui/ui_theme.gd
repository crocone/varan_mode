class_name UITheme
extends RefCounted
## Fonts, colors and a shared Theme for all UI.

const INK := Color(0.93, 0.88, 0.78)
const INK_DIM := Color(0.75, 0.69, 0.6)
const OCHRE := Color(0.85, 0.6, 0.28)
const RUST := Color(0.72, 0.3, 0.2)
const PANEL := Color(0.08, 0.06, 0.045, 0.82)
const SHADOW := Color(0, 0, 0, 0.6)

static var _theme: Theme
static var _title_font: Font
static var _ui_font: Font


static func ui_font() -> Font:
	if _ui_font == null:
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Bahnschrift", "Segoe UI", "Helvetica", "Arial", "Sans-Serif"])
		f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		_ui_font = f
	return _ui_font


static func title_font() -> Font:
	if _title_font == null:
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Constantia", "Georgia", "Palatino Linotype", "Book Antiqua", "Serif"])
		f.font_weight = 600
		_title_font = f
	return _title_font


static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = ui_font()
	t.default_font_size = 18
	t.set_color("font_color", "Label", INK)
	t.set_color("font_shadow_color", "Label", SHADOW)
	t.set_constant("shadow_offset_x", "Label", 1)
	t.set_constant("shadow_offset_y", "Label", 1)
	# buttons: text-only with an ochre underline feel
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.1, 0.075, 0.055, 0.0)
	normal.content_margin_left = 14
	normal.content_margin_right = 14
	normal.content_margin_top = 6
	normal.content_margin_bottom = 6
	var hover := normal.duplicate()
	hover.bg_color = Color(0.85, 0.6, 0.28, 0.14)
	hover.border_width_left = 3
	hover.border_color = OCHRE
	var pressed := hover.duplicate()
	pressed.bg_color = Color(0.85, 0.6, 0.28, 0.28)
	var disabled := normal.duplicate()
	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", hover)
	t.set_stylebox("pressed", "Button", pressed)
	t.set_stylebox("focus", "Button", hover)
	t.set_stylebox("disabled", "Button", disabled)
	t.set_color("font_color", "Button", INK)
	t.set_color("font_hover_color", "Button", Color(1, 0.93, 0.8))
	t.set_color("font_pressed_color", "Button", OCHRE)
	t.set_color("font_focus_color", "Button", Color(1, 0.93, 0.8))
	t.set_color("font_disabled_color", "Button", Color(0.5, 0.45, 0.4))
	t.set_font_size("font_size", "Button", 24)
	var panel := StyleBoxFlat.new()
	panel.bg_color = PANEL
	panel.corner_radius_top_left = 4
	panel.corner_radius_top_right = 4
	panel.corner_radius_bottom_left = 4
	panel.corner_radius_bottom_right = 4
	panel.content_margin_left = 24
	panel.content_margin_right = 24
	panel.content_margin_top = 18
	panel.content_margin_bottom = 18
	t.set_stylebox("panel", "PanelContainer", panel)
	# sliders
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.15)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	var fill := StyleBoxFlat.new()
	fill.bg_color = OCHRE
	fill.content_margin_top = 3
	fill.content_margin_bottom = 3
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	t.set_font_size("font_size", "CheckButton", 20)
	t.set_color("font_color", "CheckButton", INK)
	t.set_font_size("font_size", "OptionButton", 20)
	_theme = t
	return t


static func label(text: String, size := 18, col := INK, font: Font = null) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	if font != null:
		l.add_theme_font_override("font", font)
	return l
