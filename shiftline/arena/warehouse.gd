extends Node3D

const Crate = preload("props/crate.gd")
const Pickup = preload("props/pickup.gd")

var crates: Array[Crate] = []
var pickups: Array[Pickup] = []
@onready var ladders: Array[Vector3] = [
    $Structure/TideLadder/ClimbOrigin.global_position,
    $Structure/EmberLadder/ClimbOrigin.global_position,
]
@onready var spawn_groups: Array[Node3D] = [$Spawns/Tide, $Spawns/Ember]
@onready var deck_height: float = $Structure/Catwalk/ClimbExit.global_position.y

func _ready() -> void:
    # Existing clients identify placed replicas by their path relative to Match.
    for child in get_children():
        if child is Crate:
            crates.append(child)
        elif child is Pickup:
            pickups.append(child)

func spawn_point(team: int, lane: int) -> Vector3:
    return (spawn_groups[team].get_child(lane) as Marker3D).global_position
