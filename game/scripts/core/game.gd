extends Node
## Global game state: settings, input map, save/load, life statistics.

signal settings_changed

const SETTINGS_PATH := "user://settings.cfg"
const SAVE_PATH := "user://life_save.json"
const NET_SAVE_PATH := "user://net_life.json"     # your lizard when playing in someone else's world
const VERSION := "0.9.0-beta"

var settings := {
	"master_volume": 0.9,
	"sfx_volume": 1.0,
	"ambience_volume": 0.8,
	"music_volume": 0.6,
	"mouse_sensitivity": 1.0,
	"invert_y": false,
	"fov": 70.0,
	"fullscreen": false,
	"vsync": true,
	"quality": 2,        # 0 low, 1 medium, 2 high
	"hints": true,
	"player_name": "",
	"net_address": "127.0.0.1",
	"net_port": 24580,
}

## Arguments after "--" on the command line (used for automated test modes).
var cmd_args: PackedStringArray = []
var test_mode := ""

## Current session references (set by World / Main).
var world: Node = null
var player: Node = null
var main: Node = null

## Pending life data to load into a new world (from save or lineage).
var pending_load: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	cmd_args = OS.get_cmdline_user_args()
	for a in cmd_args:
		if a.begins_with("--test="):
			test_mode = a.substr(7)
	_setup_input()
	load_settings()
	apply_settings()


func _setup_input() -> void:
	var keys := {
		"move_forward": [KEY_W, KEY_UP],
		"move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"sprint": [KEY_SHIFT],
		"stalk": [KEY_C, KEY_CTRL],
		"interact": [KEY_E],
		"posture": [KEY_Q],
		"dodge": [KEY_SPACE],
		"taste": [KEY_F],
		"rest": [KEY_R],
		"pause": [KEY_ESCAPE],
		"toggle_hud": [KEY_H],
	}
	for action in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for k in keys[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(action, ev)
	var mouse := {"attack": MOUSE_BUTTON_LEFT, "tail_whip": MOUSE_BUTTON_RIGHT}
	for action in mouse:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var mb := InputEventMouseButton.new()
		mb.button_index = mouse[action]
		InputMap.action_add_event(action, mb)


# ---------------------------------------------------------------- settings

func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	for k in settings.keys():
		settings[k] = cfg.get_value("settings", k, settings[k])


func save_settings() -> void:
	var cfg := ConfigFile.new()
	for k in settings.keys():
		cfg.set_value("settings", k, settings[k])
	cfg.save(SETTINGS_PATH)


func apply_settings() -> void:
	if settings.fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if settings.vsync else DisplayServer.VSYNC_DISABLED)
	var bus := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(0.0001, settings.master_volume)))
	settings_changed.emit()


func set_setting(key: String, value) -> void:
	settings[key] = value
	apply_settings()
	save_settings()


# ---------------------------------------------------------------- save / load

## The save that belongs to the current session: a client keeps its own lizard apart.
func save_path() -> String:
	return NET_SAVE_PATH if Net.is_client() else SAVE_PATH


func has_save(path := "") -> bool:
	return FileAccess.file_exists(path if path != "" else save_path())


func write_save(data: Dictionary, path := "") -> bool:
	var sp := path if path != "" else save_path()
	data["version"] = VERSION
	data["saved_at"] = Time.get_datetime_string_from_system()
	var f := FileAccess.open(sp + ".tmp", FileAccess.WRITE)
	if f == null:
		push_warning("Could not write save file")
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	var dir := DirAccess.open("user://")
	if dir.file_exists(sp.get_file()):
		dir.remove(sp.get_file())
	dir.rename((sp + ".tmp").get_file(), sp.get_file())
	return true


func read_save(path := "") -> Dictionary:
	var sp := path if path != "" else save_path()
	if not has_save(sp):
		return {}
	var f := FileAccess.open(sp, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


func delete_save(path := "") -> void:
	var sp := path if path != "" else save_path()
	if has_save(sp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sp))


func player_name() -> String:
	var n: String = str(settings.get("player_name", "")).strip_edges()
	if n == "":
		n = OS.get_environment("USERNAME").strip_edges().substr(0, 16)
	return n if n != "" else "Varan"
