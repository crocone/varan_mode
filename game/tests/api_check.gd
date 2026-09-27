extends SceneTree
func _init():
	for m in ["set_bone_global_pose", "set_bone_global_pose_override", "set_bone_pose", "get_bone_global_rest", "set_bone_pose_rotation", "force_update_all_bone_transforms"]:
		print(m, " ", ClassDB.class_has_method("Skeleton3D", m))
	print("skin bind ", ClassDB.class_has_method("Skin", "get_bind_pose"), ClassDB.class_has_method("Skin", "get_bind_bone"))
	quit()
