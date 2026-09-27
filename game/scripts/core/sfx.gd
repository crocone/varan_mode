extends Node
## Audio manager: pooled one-shots (2D/3D), ambience beds and music.

const AUDIO_DIR := "res://assets/audio/"
const LOOPS := ["amb_day", "amb_night", "wind", "river", "music_menu", "carcass_flies", "heartbeat"]
const POOL_3D := 28
const POOL_2D := 10

var streams := {}            # name -> AudioStream
var variants := {}           # base name -> Array of names ("step" -> ["step_1", ...])
var _pool3d: Array[AudioStreamPlayer3D] = []
var _pool2d: Array[AudioStreamPlayer] = []
var _i3 := 0
var _i2 := 0
var _beds := {}              # name -> AudioStreamPlayer
var _bed_target := {}        # name -> linear volume target
var _cooldown := {}          # name -> time until can replay


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_buses()
	_load_streams()
	for i in POOL_3D:
		var p := AudioStreamPlayer3D.new()
		p.bus = "SFX"
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.unit_size = 4.0
		p.max_distance = 70.0
		p.panning_strength = 0.8
		add_child(p)
		_pool3d.append(p)
	for i in POOL_2D:
		var p2 := AudioStreamPlayer.new()
		p2.bus = "SFX"
		add_child(p2)
		_pool2d.append(p2)
	for bed in ["amb_day", "amb_night", "wind", "river", "music_menu", "heartbeat"]:
		var b := AudioStreamPlayer.new()
		b.bus = "Music" if bed == "music_menu" else ("SFX" if bed == "heartbeat" else "Ambience")
		b.stream = streams.get(bed)
		b.volume_db = -80.0
		add_child(b)
		_beds[bed] = b
		_bed_target[bed] = 0.0
	Game.settings_changed.connect(_apply_volumes)
	_apply_volumes()


func _setup_buses() -> void:
	for bus_name in ["SFX", "Ambience", "Music"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")
	# A little space for the world sounds.
	var sfx_idx := AudioServer.get_bus_index("SFX")
	if AudioServer.get_bus_effect_count(sfx_idx) == 0:
		var rev := AudioEffectReverb.new()
		rev.room_size = 0.35
		rev.damping = 0.6
		rev.wet = 0.08
		rev.dry = 1.0
		AudioServer.add_bus_effect(sfx_idx, rev)


func _apply_volumes() -> void:
	var s: Dictionary = Game.settings
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("SFX"), linear_to_db(maxf(0.0001, s.sfx_volume)))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Ambience"), linear_to_db(maxf(0.0001, s.ambience_volume)))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), linear_to_db(maxf(0.0001, s.music_volume)))


func _load_streams() -> void:
	var dir := DirAccess.open(AUDIO_DIR)
	if dir == null:
		push_warning("No audio directory")
		return
	var names := {}
	for f in dir.get_files():
		var fname: String = f
		fname = fname.trim_suffix(".remap").trim_suffix(".import")
		if fname.get_extension() == "wav":
			names[fname.get_basename()] = true
	for n in names.keys():
		var res = load(AUDIO_DIR + n + ".wav")
		if res is AudioStream:
			if n in LOOPS and res is AudioStreamWAV:
				var w: AudioStreamWAV = res
				w.loop_mode = AudioStreamWAV.LOOP_FORWARD
				w.loop_begin = 0
				w.loop_end = int(w.get_length() * w.mix_rate)
			streams[n] = res
			# register numbered variants: "step_2" -> base "step"
			var parts: PackedStringArray = n.rsplit("_", true, 1)
			if parts.size() == 2 and parts[1].is_valid_int():
				if not variants.has(parts[0]):
					variants[parts[0]] = []
				variants[parts[0]].append(n)


func _resolve(sound: String) -> AudioStream:
	if variants.has(sound):
		var arr: Array = variants[sound]
		return streams.get(arr[randi() % arr.size()])
	return streams.get(sound)


func play_at(sound: String, pos: Vector3, volume_db := 0.0, pitch := 1.0, max_dist := 60.0, cooldown := 0.0) -> void:
	if cooldown > 0.0:
		var key := sound + str(snappedf(pos.x, 4.0)) + str(snappedf(pos.z, 4.0))
		var now := Time.get_ticks_msec() / 1000.0
		if _cooldown.get(key, 0.0) > now:
			return
		_cooldown[key] = now + cooldown
	var st := _resolve(sound)
	if st == null:
		return
	var p := _pool3d[_i3]
	_i3 = (_i3 + 1) % POOL_3D
	p.stream = st
	p.global_position = pos
	p.volume_db = volume_db
	p.pitch_scale = pitch * randf_range(0.94, 1.06)
	p.max_distance = max_dist
	p.unit_size = clampf(max_dist / 14.0, 0.5, 10.0)
	p.play()


func play(sound: String, volume_db := 0.0, pitch := 1.0) -> void:
	var st := _resolve(sound)
	if st == null:
		return
	var p := _pool2d[_i2]
	_i2 = (_i2 + 1) % POOL_2D
	p.stream = st
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()


func ui(sound := "ui_click") -> void:
	play(sound, -4.0)


## Set target linear volume (0..1) for an ambience bed; volumes glide smoothly.
func set_bed(bed: String, vol: float) -> void:
	_bed_target[bed] = clampf(vol, 0.0, 1.0)


func stop_all_beds() -> void:
	for k in _bed_target.keys():
		_bed_target[k] = 0.0


func _process(delta: float) -> void:
	for bed in _beds.keys():
		var b: AudioStreamPlayer = _beds[bed]
		if b.stream == null:
			continue
		var cur := db_to_linear(b.volume_db) if b.playing else 0.0
		var tgt: float = _bed_target[bed]
		var rate := 0.35 if bed == "music_menu" else 0.6
		cur = move_toward(cur, tgt, rate * delta)
		if cur <= 0.001:
			if b.playing:
				b.stop()
			b.volume_db = -80.0
		else:
			if not b.playing:
				b.play(randf() * maxf(0.0, b.stream.get_length() - 1.0))
			b.volume_db = linear_to_db(cur)
