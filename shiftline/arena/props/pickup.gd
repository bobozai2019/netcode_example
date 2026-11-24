extends Node3D

const SceneReplica = preload("res://addons/netcode/scene_replicator.gd")

@export var map_id := 0
@export var kind := 0
var match_id := 0
var generation := 0
var available := true
var refresh_at := 0.0
@onready var sync: SceneReplica = $Sync
@onready var item: Node3D = $Item

func reset_for(round_id: int) -> void:
    match_id = round_id
    generation += 1
    available = true
    refresh_at = 0.0

func present(time: float) -> void:
    item.visible = available
    item.rotation.y = time * 0.7
    item.position.y = sin(time * 2.4 + map_id) * 0.055
