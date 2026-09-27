class_name PartSkin
extends RefCounted
## Binds a Blender-built skinned model onto a procedural "rigid parts" rig
## (MammalRig / BirdRig / SmallRig). Every rigid part MeshInstance3D of the
## rig became one bone of the model; each frame the bone follows the part's
## transform relative to its rest pose, so all existing procedural animation
## drives a single smooth, textured mesh.

var rig: Node3D
var root: Node3D
var skel: Skeleton3D
var parts: Array = []            # MeshInstance3D per bone slot
var bone_ids := PackedInt32Array()
var rest_inv: Array = []         # (rig-space rest transform of part)^-1
var bone_rest: Array = []        # skeleton-space global rest
var K := Transform3D.IDENTITY    # rig space -> skeleton space helper
var K_inv := Transform3D.IDENTITY

static var _scenes := {}
static var disabled := false


## Rigid part MeshInstances in deterministic depth-first order.
static func collect_parts(n: Node, out: Array, skip: Node = null) -> void:
	for ch in n.get_children():
		if ch == skip:
			continue
		if ch is MeshInstance3D and (ch as MeshInstance3D).mesh != null:
			out.append(ch)
		collect_parts(ch, out, skip)


static func part_name(i: int, mi: MeshInstance3D) -> String:
	var key := mi.mesh.resource_name if mi.mesh != null else ""
	if key == "":
		key = "part"
	return "b%02d_%s" % [i, key.replace("/", "_")]


static func try_attach(r: Node3D, species: String) -> PartSkin:
	if disabled:
		return null
	var path := "res://assets/creatures/%s.glb" % species
	if not ResourceLoader.exists(path):
		return null
	if not _scenes.has(species):
		_scenes[species] = load(path)
	var ps: PackedScene = _scenes[species]
	if ps == null:
		return null
	var s := PartSkin.new()
	if not s._attach(r, ps):
		return null
	return s


func _attach(r: Node3D, ps: PackedScene) -> bool:
	rig = r
	var list: Array = []
	collect_parts(rig, list)
	root = ps.instantiate()
	rig.add_child(root)
	skel = _find_skel(root)
	if skel == null:
		root.queue_free()
		return false
	var rig_inv := rig.global_transform.affine_inverse() if rig.is_inside_tree() else Transform3D.IDENTITY
	K = _rel(rig, skel)
	K_inv = K.affine_inverse()
	for i in list.size():
		var mi: MeshInstance3D = list[i]
		var bi := skel.find_bone(part_name(i, mi))
		if bi < 0:
			continue
		parts.append(mi)
		bone_ids.append(bi)
		rest_inv.append(_rel(rig, mi).affine_inverse())
		bone_rest.append(skel.get_bone_global_rest(bi))
		mi.visible = false
	if parts.is_empty():
		root.queue_free()
		return false
	for m in root.find_children("*", "MeshInstance3D", true, false):
		(m as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return true


## Transform of node n relative to ancestor a (works outside the scene tree).
static func _rel(a: Node3D, n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != a:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


static func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for ch in n.get_children():
		var r := _find_skel(ch)
		if r != null:
			return r
	return null


func update() -> void:
	for k in parts.size():
		var mi: MeshInstance3D = parts[k]
		var D: Transform3D = _rel(rig, mi) * (rest_inv[k] as Transform3D)
		var par := mi.get_parent() as Node3D
		if par != null and not par.visible:
			D = D.scaled_local(Vector3.ONE * 0.0001)
		var ancestor := par
		while ancestor != null and ancestor != rig:
			if not ancestor.visible:
				D = D.scaled_local(Vector3.ONE * 0.0001)
				break
			ancestor = ancestor.get_parent() as Node3D
		var G: Transform3D = K_inv * D * K * (bone_rest[k] as Transform3D)
		skel.set_bone_pose(bone_ids[k], G)


# ------------------------------------------------------------------ fur shells

const FUR := {"dingo": [0.022, 120.0], "wallaby": [0.018, 130.0], "mouse": [0.035, 90.0]}
const SHELLS := 9
const FUR_DIST := 14.0
static var _fur_mats := {}      # species -> [base_with_shells, base_plain]
static var _strand_tex: ImageTexture
var fur_mi: MeshInstance3D = null
var fur_on := false
var species_id := ""


static func _strands() -> ImageTexture:
	if _strand_tex == null:
		var img := Image.create(256, 256, false, Image.FORMAT_L8)
		var rng := RandomNumberGenerator.new()
		rng.seed = 42
		for y in 256:
			for x in 256:
				img.set_pixel(x, y, Color(rng.randf(), 0, 0))
		_strand_tex = ImageTexture.create_from_image(img)
	return _strand_tex


func setup_fur(species: String) -> void:
	species_id = species
	if not FUR.has(species):
		return
	var mis := root.find_children("*", "MeshInstance3D", true, false)
	if mis.is_empty():
		return
	fur_mi = mis[0]
	if not _fur_mats.has(species):
		var base: Material = fur_mi.mesh.surface_get_material(0)
		if not (base is StandardMaterial3D):
			return
		var sm: StandardMaterial3D = base
		var furred: StandardMaterial3D = sm.duplicate()
		var prev: Material = furred
		var shader: Shader = load("res://assets/shaders/fur_shell.gdshader")
		for i in SHELLS:
			var m := ShaderMaterial.new()
			m.shader = shader
			m.set_shader_parameter("albedo_tex", sm.albedo_texture)
			m.set_shader_parameter("rough_tex", sm.roughness_texture)
			m.set_shader_parameter("strand_tex", _strands())
			m.set_shader_parameter("layer", float(i + 1) / SHELLS)
			m.set_shader_parameter("fur_len", FUR[species][0])
			m.set_shader_parameter("density", FUR[species][1])
			prev.next_pass = m
			prev = m
		_fur_mats[species] = [furred, base]
	fur_on = false


func update_fur(cam_pos: Vector3) -> void:
	if fur_mi == null or not _fur_mats.has(species_id):
		return
	var want := fur_mi.global_position.distance_to(cam_pos) < FUR_DIST * maxf(1.0, rig.scale.x * 2.0)
	if want != fur_on:
		fur_on = want
		fur_mi.set_surface_override_material(0, _fur_mats[species_id][0] if want else null)
