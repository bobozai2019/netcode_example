extends RefCounted

static func reach(rig: Skeleton3D, upper: int, lower: int, hand: int, target: Vector3, pole: Vector3) -> void:
	var root := rig.get_bone_global_pose(upper).origin
	var rest_elbow := rig.get_bone_global_pose(lower).origin
	var rest_hand := rig.get_bone_global_pose(hand).origin
	var first := root.distance_to(rest_elbow)
	var second := rest_elbow.distance_to(rest_hand)
	var distance := clampf(root.distance_to(target), absf(first - second) + 0.01, first + second - 0.01)
	var aim := root.direction_to(target)
	var bend := (pole - root).slide(aim).normalized()
	var along := (first * first - second * second + distance * distance) / (2.0 * distance)
	var elbow := root + aim * along + bend * sqrt(maxf(0.0, first * first - along * along))
	aim_bone(rig, upper, rest_elbow - root, elbow - root)
	var actual_elbow := rig.get_bone_global_pose(lower).origin
	aim_bone(rig, lower, rig.get_bone_global_pose(hand).origin - actual_elbow, target - actual_elbow)

static func aim_bone(rig: Skeleton3D, bone: int, from: Vector3, to: Vector3) -> void:
	if from.is_zero_approx() or to.is_zero_approx():
		return
	var parent := rig.get_bone_parent(bone)
	var to_parent := rig.get_bone_global_pose(parent).basis.orthonormalized().transposed()
	var turn := Quaternion((to_parent * from).normalized(), (to_parent * to).normalized())
	# Changing only rotation preserves the imported bone lengths and scale across frames.
	rig.set_bone_pose_rotation(bone, (turn * rig.get_bone_pose_rotation(bone)).normalized())
