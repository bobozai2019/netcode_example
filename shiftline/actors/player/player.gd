extends CharacterBody3D

const SceneReplica = preload("res://addons/netcode/scene_replicator.gd")

const Rules = preload("../../net/config.gd")
const Soldier = preload("soldier.gd")
const WALK_SPEED := 5.3
const CROUCH_SPEED := 2.8
const CLIMB_SPEED := 2.55
const HEIGHT := 1.84
const CROUCH_HEIGHT := 1.2

@export var slot_index := 0
var player_id := 0
var life_id := 0
var match_id := 0
var team := 0
var hp := 0
var kills := 0
var deaths := 0
var magazine := 0
var reserve := 0
var grenades := 0
var pose := Rules.Pose.IDLE
var action := Rules.Action.IDLE
var action_seq := 0
var ack_input_seq := 0
var ping_ms := -1
var nickname := ""
var active := false
var alive := false
var yaw := 0.0
var pitch := 0.0
var action_until := 0.0
var respawn_at := 0.0

@onready var sync: SceneReplica = $Sync
@onready var collider: CollisionShape3D = $Collision
@onready var shell := collider.shape as CapsuleShape3D
@onready var soldier: Soldier = $Soldier
var input_move := Vector2.ZERO
var input_buttons := 0
var input_at := -100.0
var request_seq := 0
var request_result := Rules.Result.STALE
var trigger := false
var tap_pending := false
var next_shot_at := 0.0
var throw_dir := Vector3.ZERO
var throw_at := 0.0
var previous_jump := false
var climbing := false
var rendered_life := -1
var rendered_round := -1

func _ready() -> void:
    set_meta("player", self)

func clear_input() -> void:
    input_move = Vector2.ZERO
    input_buttons = 0
    input_at = -100.0
    request_seq = 0
    request_result = Rules.Result.STALE
    ack_input_seq = 0
    trigger = false
    tap_pending = false
    next_shot_at = 0.0
    previous_jump = false
    climbing = false
    throw_at = 0.0
    throw_dir = Vector3.ZERO

func occupy(id: int, squad: int, round_id: int, spawn: Vector3, host: bool) -> void:
    active = true
    player_id = id
    team = squad
    nickname = "Player %d" % id
    ping_ms = 0 if host else -1
    kills = 0
    deaths = 0
    spawn_life(round_id, spawn)

func vacate() -> void:
    active = false
    alive = false
    player_id = 0
    nickname = ""
    ping_ms = -1
    respawn_at = 0.0
    clear_input()
    collision_layer = 0
    soldier.hide()

func spawn_life(round_id: int, spawn: Vector3) -> void:
    clear_input()
    match_id = round_id
    life_id += 1
    alive = true
    position = spawn
    velocity = Vector3.ZERO
    yaw = -PI / 2.0 if team == 0 else PI / 2.0
    pitch = 0.0
    hp = Rules.HEALTH
    magazine = Rules.MAGAZINE
    reserve = Rules.START_RESERVE
    grenades = 1
    pose = Rules.Pose.IDLE
    respawn_at = 0.0
    set_action(Rules.Action.IDLE, 0.0)
    set_crouch(false)
    collision_layer = 2

func set_action(kind: int, until: float) -> void:
    action = kind
    action_seq += 1
    action_until = until

func set_crouch(crouched: bool) -> void:
    var target := CROUCH_HEIGHT if crouched else HEIGHT
    if shell.height != target:
        shell.height = target
        collider.position.y = target / 2

func eye_height() -> float:
    return 1.02 if pose == Rules.Pose.CROUCH else 1.57

func facing() -> Vector3:
    return Basis.from_euler(Vector3(pitch, yaw, 0)) * Vector3.FORWARD

func simulate(delta: float, now: float, ladders: Array[Vector3], deck: float) -> void:
    if now - input_at > Rules.INPUT_TIMEOUT:
        input_move = Vector2.ZERO
        input_buttons = 0
        trigger = false
    var desired := Basis(Vector3.UP, yaw) * Vector3(input_move.x, 0, input_move.y)
    var crouched := (input_buttons & Rules.Buttons.CROUCH) != 0
    var jump := (input_buttons & Rules.Buttons.JUMP) != 0
    if not crouched and shell.height < HEIGHT:
        var clear := PhysicsRayQueryParameters3D.create(position + Vector3.UP * CROUCH_HEIGHT,
            position + Vector3.UP * HEIGHT, 3, [get_rid()])
        crouched = not get_world_3d().direct_space_state.intersect_ray(clear).is_empty()
    set_crouch(crouched)
    for ladder in ladders:
        if absf(position.x - ladder.x) > 0.82 or absf(position.z - ladder.z) > 0.9:
            continue
        var near: bool = absf(position.z - ladder.z) < (0.72 if climbing else 0.52)
        if not near or (not climbing and absf(desired.z) < 0.35):
            continue
        if not climbing and position.y < deck - 0.12 and desired.z >= 0:
            continue
        if not climbing and position.y >= deck - 0.12 and desired.z <= 0:
            continue
        if climbing and position.y <= 0.1 and desired.z > 0:
            break
        if position.y >= deck + 0.035 and desired.z < 0:
            position.z = ladder.z - 0.78
            break
        climbing = true
        pose = Rules.Pose.CLIMB
        velocity = Vector3((ladder.x - position.x) * 8, -desired.z * CLIMB_SPEED, (ladder.z - position.z) * 8)
        move_and_slide()
        previous_jump = jump
        return
    climbing = false
    var speed := CROUCH_SPEED if crouched else WALK_SPEED
    velocity.x = desired.x * speed
    velocity.z = desired.z * speed
    if is_on_floor():
        velocity.y = 4.15 if jump and not previous_jump and not crouched else -0.3
    else:
        velocity.y = maxf(velocity.y - 15.0 * delta, -24.0)
    previous_jump = jump
    move_and_slide()
    var motion := get_real_velocity()
    var moving := Vector2(motion.x, motion.z).length_squared() > 0.04
    pose = Rules.Pose.CROUCH if crouched else (Rules.Pose.RUN if moving else Rules.Pose.IDLE)

func present(delta: float, local: bool, authoritative: bool, clock: float) -> void:
    soldier.visible = active and not local
    if not authoritative:
        collision_layer = 2 if active and alive else 0
        set_crouch(pose == Rules.Pose.CROUCH)
    if not soldier.visible:
        return
    var snap := rendered_life != life_id or rendered_round != match_id
    var weight := 1.0 if snap else 1.0 - exp(-delta * 19.0)
    soldier.global_position = soldier.global_position.lerp(global_position, weight)
    soldier.rotation.y = lerp_angle(soldier.rotation.y, yaw + PI, weight)
    rendered_life = life_id
    rendered_round = match_id
    soldier.present(team, pose, action, action_seq, clock, action_until, delta)
