
extends Node

const EnemyType = preload("res://actors/enemy_type.gd")

enum Kind { MOTION, VITALS, ENEMY }
enum Species { GRUNT, CHARGER, BOSS, PRACTICE }

@export var kind: Kind
var entity_id := 0
var controller := 0
var generation := 1
var position_xz := Vector2.ZERO
var facing := Vector2.DOWN
var velocity := Vector2.ZERO
var source_step := 0
var hp := 100
var version := 0
var invulnerable_until := 0
var team := 0
var species := Species.GRUNT
var target := 0
var windup_until := 0
var charge_direction := Vector2.ZERO
var cooldown_until := 0
var next_request := 0
var request_started := 0
var waiting := false
var lane := Vector2.ZERO
var enemy_type: EnemyType

const MIN_BLEND := 0.032
const MAX_BLEND := 0.10
const RESET_DISTANCE_SQUARED := 9.0
var local_motion_writer := false
var is_visual_proxy := false
var visual_position := Vector2.ZERO
var visual_facing := Vector2.DOWN
var visual_step_distance := 0.0
var visual_packet_gap_ms := 0.0
var visual_last_motion_us := 0
var visual_generation := 0
var sample_instant_us := 0
var sampled_step := 0
var goal_position := Vector2.ZERO
var goal_facing := Vector2.DOWN
var blend_origin := Vector2.ZERO
var facing_origin := Vector2.DOWN
var blend_elapsed := 0.0
var blend_duration := 0.05

@onready var sync: NetcodeSharedReplicator = $Sync

func permit(requester: int) -> bool:
	return requester == controller

func observed_position() -> Vector2:
	return visual_position if is_visual_proxy else position_xz

func observed_facing() -> Vector2:
	return visual_facing if is_visual_proxy else facing

func advance_enemy_pose(delta: float, now: int, raw: bool) -> void:
	if local_motion_writer:
		is_visual_proxy = false
		return
	visual_packet_gap_ms = 0.0
	if not is_visual_proxy or generation != visual_generation or goal_position.distance_squared_to(position_xz) > RESET_DISTANCE_SQUARED:
		is_visual_proxy = true
		visual_generation = generation
		visual_position = position_xz
		visual_facing = facing
		goal_position = position_xz
		goal_facing = facing
		blend_origin = position_xz
		facing_origin = facing
		blend_elapsed = blend_duration
		sample_instant_us = now
		sampled_step = source_step
		visual_last_motion_us = 0
		visual_step_distance = 0.0
		return
	if source_step != sampled_step:
		visual_packet_gap_ms = float(now - sample_instant_us) / 1000.0
		blend_duration = clampf(visual_packet_gap_ms / 1000.0, MIN_BLEND, MAX_BLEND)
		sample_instant_us = now
		sampled_step = source_step
	if position_xz != goal_position or facing != goal_facing:
		if position_xz != goal_position:
			visual_last_motion_us = now
		blend_origin = visual_position
		facing_origin = visual_facing
		goal_position = position_xz
		goal_facing = facing
		blend_elapsed = 0.0
	var previous := visual_position
	if raw:
		visual_position = position_xz
		visual_facing = facing
	else:
		blend_elapsed = minf(blend_elapsed + delta, blend_duration)
		var weight := blend_elapsed / blend_duration
		visual_position = blend_origin.lerp(goal_position, weight)
		visual_facing = facing_origin.slerp(goal_facing, weight)
	visual_step_distance = previous.distance_to(visual_position)
