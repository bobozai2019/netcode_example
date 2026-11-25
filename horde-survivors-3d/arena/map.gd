
extends Node3D

const Rules = preload("res://combat/rules.gd")

@export var half_extent := Vector2(33, 23)
@export var west_wave_region: Rect2
@export var east_wave_region: Rect2
@export var fallback_spawn_distance := 23.0

@onready var player_spawns: Array[Marker3D] = [$Spawns/Tide, $Spawns/Ember]
@onready var boss_spawn: Marker3D = $Spawns/Boss
var obstacles: Array[Rect2] = []

func _ready() -> void:
	# Cache the authored box footprints once for deterministic XZ movement.
	for body: StaticBody3D in $Cover.get_children():
		var collider: CollisionShape3D = body.get_node("Collision")
		var box := collider.shape as BoxShape3D
		var shape_pose := global_transform.affine_inverse() * collider.global_transform
		var center := Vector2(shape_pose.origin.x, shape_pose.origin.z)
		var axes := shape_pose.basis
		var half := box.size * 0.5
		var extent := Vector2(
			absf(axes.x.x) * half.x + absf(axes.y.x) * half.y + absf(axes.z.x) * half.z,
			absf(axes.x.z) * half.x + absf(axes.y.z) * half.y + absf(axes.z.z) * half.z)
		obstacles.append(Rect2(center - extent, extent * 2.0))

func move(origin: Vector2, offset: Vector2, radius := Rules.PLAYER_RADIUS) -> Vector2:
	var next := origin
	next.x = clampf(origin.x + offset.x, -half_extent.x, half_extent.x)
	if blocked(next, radius):
		next.x = origin.x
	next.y = clampf(origin.y + offset.y, -half_extent.y, half_extent.y)
	if blocked(next, radius):
		next.y = origin.y
	return next

func blocked(point: Vector2, radius: float) -> bool:
	for rect in obstacles:
		if rect.grow(radius).has_point(point):
			return true
	return false

func spawn_origin(team: int) -> Vector2:
	var marker := player_spawns[team].position
	return Vector2(marker.x, marker.z)

func boss_origin() -> Vector2:
	return Vector2(boss_spawn.position.x, boss_spawn.position.z)

func enemy_origin(rng: RandomNumberGenerator, side: float, spawn_scale: float) -> Vector2:
	var region := west_wave_region if side < 0.0 else east_wave_region
	var magnitude := minf(absf(region.position.x), absf(region.end.x))
	var point := Vector2(side * rng.randf_range(magnitude, magnitude + region.size.x),
		rng.randf_range(region.position.y, region.end.y)) * spawn_scale
	if blocked(point, 0.8):
		point.x = side * fallback_spawn_distance
	return point
