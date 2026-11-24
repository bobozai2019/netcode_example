extends Node3D

const Rules = preload("../../net/config.gd")
const ArmPose = preload("../animation/arm_pose.gd")

@onready var skeleton: Skeleton3D = $Arms/arms/Skeleton3D
@onready var mesh: MeshInstance3D = $Arms/arms/Skeleton3D/arms_mesh
@onready var rifle: Node3D = $Rifle
@onready var magazine: Node3D = $Rifle/Magazine
@onready var seated_magazine := magazine.position
@onready var grenade: Node3D = $Grenade
@onready var sleeve := mesh.material_override as ShaderMaterial
@onready var flash: MeshInstance3D = $Rifle/MuzzleFlash

var last_team := -1
var step := 0.0
var recoil := 0.0
var action_sequence := -1
var flash_time := 0.0
var arm_bones: Dictionary = {}

func _ready() -> void:
    for side in ["l", "r"]:
        for kind in ["bicep", "forearm", "wrist"]:
            var index := skeleton.find_bone("%s.%s" % [kind, side])
            arm_bones["%s.%s" % [kind, side]] = [index, skeleton.get_bone_pose_rotation(index)]

func animate(delta: float, team: int, pose: int, action: int, seq: int, now: float, until: float) -> void:
    if team != last_team:
        sleeve.set_shader_parameter("fabric_tint", Rules.team_color(team).darkened(0.22))
        last_team = team
    if action == Rules.Action.FIRE and seq != action_sequence:
        recoil = 1.0
        flash_time = 0.048
    action_sequence = seq
    recoil = maxf(0.0, recoil - 11 * delta)
    flash_time = maxf(0.0, flash_time - delta)
    flash.visible = flash_time > 0.0
    flash.rotate_x(delta * 31.0)
    var walking := pose == Rules.Pose.RUN or pose == Rules.Pose.CLIMB
    step += delta * (10.5 if walking else 1.9)
    position.x = sin(step) * (0.013 if walking else 0.005)
    position.y = cos(step * 2) * (0.012 if walking else 0.003)
    var reload := 0.0
    var toss := 0.0
    var progress := 0.0
    if action == Rules.Action.RELOAD:
        progress = clampf(1.0 - (until - now) / Rules.RELOAD_SECONDS, 0, 1)
        reload = sin(progress * PI)
    elif action == Rules.Action.THROW:
        progress = clampf(1.0 - (until - now) / Rules.THROW_SECONDS, 0, 1)
        toss = sin(progress * PI)
    var ladder := pose == Rules.Pose.CLIMB
    rifle.position = Vector3(0.24 - reload * 0.04, -0.27 - reload * 0.07, -0.58 + recoil * 0.07)
    rifle.rotation = Vector3(recoil * 0.14 - reload * 0.33, -PI / 2.0 - reload * 0.25, -reload * 0.55)
    rifle.visible = action != Rules.Action.THROW and not ladder
    var clip_motion := smoothstep(0.13, 0.35, progress) * (1.0 - smoothstep(0.58, 0.82, progress)) if action == Rules.Action.RELOAD else 0.0
    magazine.position = seated_magazine + Vector3(0.03, -0.25, 0.36) * clip_motion
    magazine.rotation.z = -clip_motion * 0.55
    grenade.visible = action == Rules.Action.THROW and progress < Rules.THROW_RELEASE / Rules.THROW_SECONDS
    grenade.position = Vector3(0.20, -0.27 + toss * 0.24, -0.50 + toss * 0.17)
    var right := rifle.transform * Vector3(0.10, -0.09, 0.061)
    var left := rifle.transform * Vector3(-0.39, -0.14, 0.10)
    if action == Rules.Action.RELOAD:
        var clip_hand := rifle.transform * (magazine.transform * Vector3(-0.03, -0.18, 0.11))
        var support_motion := smoothstep(0.06, 0.24, progress) * (1.0 - smoothstep(0.78, 0.96, progress))
        left = left.lerp(clip_hand, support_motion)
    if action == Rules.Action.THROW:
        right = grenade.position + Vector3(0.02 + toss * 0.14, -0.04, 0.09)
        left = Vector3(0.02, -0.46, -0.46)
    if ladder:
        right = Vector3(0.32, -0.06 + sin(step) * 0.19, -0.55)
        left = Vector3(-0.11, -0.07 - sin(step) * 0.19, -0.55)
    var wrist_rotation := rifle.basis.orthonormalized() * Basis(Vector3.UP, PI / 2.0) if rifle.visible else Basis.IDENTITY
    grip("r", right, Vector3(0.72, -0.59, -0.33), wrist_rotation * Vector3(-0.24, 0.78, -0.58))
    grip("l", left, Vector3(-0.35, -0.77, -0.37), wrist_rotation * Vector3(0.36, 0.43, -0.82))

func grip(side: String, hand: Vector3, pole: Vector3, palm: Vector3) -> void:
    var upper: Array = arm_bones["bicep." + side]
    var lower: Array = arm_bones["forearm." + side]
    var wrist: Array = arm_bones["wrist." + side]
    for bone in [upper, lower, wrist]:
        skeleton.set_bone_pose_rotation(bone[0], bone[1])
    var target := skeleton.to_local(to_global(hand))
    ArmPose.reach(skeleton, upper[0], lower[0], wrist[0], target, skeleton.to_local(to_global(pole)))
    var palm_axis := skeleton.get_bone_global_pose(wrist[0]).basis.y
    var palm_goal := skeleton.global_basis.inverse() * (global_basis * palm)
    ArmPose.aim_bone(skeleton, wrist[0], palm_axis, palm_goal)
