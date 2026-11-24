extends Node3D

const SceneReplica = preload("res://addons/netcode/scene_replicator.gd")

const Rules = preload("../../net/config.gd")

@export var map_id := 0
var match_id := 0
var hp := Rules.CRATE_HEALTH
var destroyed := false
@onready var sync: SceneReplica = $Sync
@onready var cover: StaticBody3D = $Cover
@onready var model: Node3D = $Model
@onready var debris: Node3D = $Debris
var applied := false

func _ready() -> void:
    cover.set_meta("crate", self)

func reset_for(round_id: int) -> void:
    match_id = round_id
    hp = Rules.CRATE_HEALTH
    destroyed = false
    present()

func damage(amount: int) -> void:
    hp = maxi(0, hp - amount)
    destroyed = hp == 0
    present()

func present() -> void:
    if applied == destroyed:
        return
    applied = destroyed
    cover.collision_layer = 0 if destroyed else 1
    model.visible = not destroyed
    debris.visible = destroyed
