extends Node3D

const Rules = preload("../../net/config.gd")
const ArmPose = preload("../animation/arm_pose.gd")
const READY_POSE_TIME := 0.025

@onready var rig: Node3D = $Rig
@onready var player: AnimationPlayer = $Rig/AnimationPlayer
@onready var skeleton: Skeleton3D = $Rig/CharacterArmature/Skeleton3D
@onready var mount: BoneAttachment3D = $Rig/CharacterArmature/Skeleton3D/Index1_R
@onready var rifle: Node3D = mount.get_node("Rifle")
@onready var magazine: Node3D = rifle.get_node("Magazine")
@onready var magazine_home := magazine.position
@onready var rifle_bone := mount.bone_idx
@onready var tossed: Node3D = mount.get_node("Grenade")

var last_team := -1
var current := ""
var holding_aim := false
var sequence := -1
var restore_pose: Dictionary[int, Quaternion] = {}
@onready var left_upper := skeleton.find_bone("UpperArm.L")
@onready var left_lower := skeleton.find_bone("LowerArm.L")
@onready var left_hand := skeleton.find_bone("Middle1.L")

func present(team: int, pose: int, action: int, seq: int, clock: float, until: float, delta: float) -> void:
    for bone in restore_pose:
        skeleton.set_bone_pose_rotation(bone, restore_pose[bone])
    restore_pose.clear()
    if team != last_team:
        tint(team)
        last_team = team
    var clip := "Idle_Shoot"
    match pose:
        Rules.Pose.RUN: clip = "Run_Gun"
        Rules.Pose.CROUCH: clip = "Duck"
        Rules.Pose.CLIMB: clip = "Run_Gun"
    match action:
        Rules.Action.DOWN: clip = "Death"
        Rules.Action.FIRE: clip = "Run_Shoot" if pose == Rules.Pose.RUN else "Idle_Shoot"
        Rules.Action.THROW: clip = "Idle_Shoot"
    var hold := clip == "Idle_Shoot" and action != Rules.Action.FIRE
    if current != clip or holding_aim != hold or (seq != sequence and action == Rules.Action.DOWN):
        player.play(clip, 0.11, 0.0 if hold else 1.0)
        if hold:
            player.seek(READY_POSE_TIME)
        current = clip
        holding_aim = hold
    sequence = seq
    player.speed_scale = 0.75 if pose == Rules.Pose.CLIMB else 1.0
    player.advance(delta)
    var lift := 0.0
    var turn := 0.0
    var slip := 0.0
    var support_motion := 0.0
    if action == Rules.Action.RELOAD:
        var t := clampf(1.0 - (until - clock) / Rules.RELOAD_SECONDS, 0, 1)
        lift = sin(t * PI) * 0.49
        turn = sin(t * PI) * 0.23
        slip = smoothstep(0.13, 0.35, t) * (1.0 - smoothstep(0.58, 0.82, t))
        support_motion = smoothstep(0.06, 0.24, t) * (1.0 - smoothstep(0.78, 0.96, t))
    elif action == Rules.Action.THROW:
        var t := clampf(1.0 - (until - clock) / Rules.THROW_SECONDS, 0, 1)
        lift = -sin(t * PI) * 1.4
        turn = -sin(t * PI) * 0.42
    elif pose == Rules.Pose.CLIMB:
        lift = -0.92 + sin(clock * 9.0) * 0.22
    if lift != 0.0:
        bend("UpperArm.R", lift, turn)
        if action != Rules.Action.RELOAD:
            bend("UpperArm.L", lift * 0.80, -turn)
            bend("LowerArm.L", -lift * 0.42, 0.0)
    if rifle:
        rifle.visible = action != Rules.Action.THROW and pose != Rules.Pose.CLIMB
        magazine.position = magazine_home + Vector3(0.03, -0.23, 0.18) * slip
        magazine.rotation.z = -0.35 * slip
        tossed.visible = action == Rules.Action.THROW and clock < until - Rules.THROW_SECONDS + Rules.THROW_RELEASE
        if rifle.visible and (clip == "Idle_Shoot" or action in [Rules.Action.FIRE, Rules.Action.RELOAD]):
            support_rifle(support_motion)

func support_rifle(magazine_grip: float) -> void:
    for bone in [left_upper, left_lower]:
        restore_pose[bone] = skeleton.get_bone_pose_rotation(bone)
    var mounted := skeleton.get_bone_global_pose(rifle_bone) * rifle.transform
    var hand := mounted * Vector3(-0.54, 0.11, 0.06)
    if magazine_grip > 0.0:
        hand = hand.lerp(mounted * magazine.transform * Vector3(-0.07, -0.16, 0.03), magazine_grip)
    var pole := skeleton.to_local(rig.to_global(Vector3(0.65, 0.91, 0.31)))
    ArmPose.reach(skeleton, left_upper, left_lower, left_hand, hand, pole)

func bend(bone_name: String, angle: float, turn: float) -> void:
    var bone := skeleton.find_bone(bone_name)
    if bone >= 0:
        restore_pose[bone] = skeleton.get_bone_pose_rotation(bone)
        skeleton.set_bone_pose_rotation(bone, restore_pose[bone] * Quaternion.from_euler(Vector3(angle, 0, turn)))

func tint(team: int) -> void:
    for mesh: MeshInstance3D in rig.find_children("*", "MeshInstance3D", true, false):
        for index in mesh.mesh.get_surface_count():
            var base := mesh.mesh.surface_get_material(index) as StandardMaterial3D
            if base and base.resource_name in ["Character_Main", "Pants"]:
                var dyed := base.duplicate() as StandardMaterial3D
                dyed.albedo_color = Rules.team_color(team).darkened(0.14 if base.resource_name == "Character_Main" else 0.62)
                mesh.set_surface_override_material(index, dyed)
