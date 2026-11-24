extends Node3D

const SceneReplica = preload("res://addons/netcode/scene_replicator.gd")

var match_id := 0
var thrower_id := 0
var thrower_team := 0
var velocity := Vector3.ZERO
var detonate_at := 0.0
@onready var appearance: Node3D = $Appearance
@onready var sync: SceneReplica = $Sync

func simulate(delta: float) -> void:
    velocity.y -= 10.5 * delta
    var next := position + velocity * delta
    var query := PhysicsRayQueryParameters3D.create(position, next, 1)
    var hit := get_world_3d().direct_space_state.intersect_ray(query)
    if hit.is_empty():
        position = next
    else:
        position = hit.position + hit.normal * 0.035
        velocity = velocity.bounce(hit.normal) * 0.58
        if hit.normal.y > 0.7 and absf(velocity.y) < 0.55:
            velocity.x *= 0.65
            velocity.z *= 0.65

func present(delta: float, current_match: int, host: bool) -> void:
    var show_model := (sync.initialized or host) and match_id == current_match
    if show_model:
        if not appearance.visible: appearance.global_position = global_position
        appearance.global_position = appearance.global_position.lerp(global_position, 1 - exp(-delta * 22))
        appearance.rotate_x(velocity.length() * delta * 0.65)
    appearance.visible = show_model
