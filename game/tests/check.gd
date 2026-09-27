extends SceneTree
## Loads every script to surface parse errors:  godot --headless --path game --script res://tests/check.gd

func _init() -> void:
	var files: Array = []
	_collect("res://scripts", files)
	_collect("res://tests", files)
	var bad := 0
	for f in files:
		var s = load(f)
		if s == null:
			bad += 1
			print("FAILED: ", f)
	print("checked ", files.size(), " scripts, failed: ", bad)
	quit()


func _collect(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_collect(dir.path_join(sub), out)
