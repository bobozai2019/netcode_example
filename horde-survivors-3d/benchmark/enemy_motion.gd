extends RefCounted

const State = preload("res://actors/state.gd")
const MAX_SAMPLES := 8192
const MOVEMENT_TAIL_US := 150000
const HOLD_DISTANCE := 0.001

var frames: Array[float] = []
var gaps: Array[float] = []
var steps: Array[float] = []
var errors: Array[float] = []
var rng := RandomNumberGenerator.new()
var gaps_seen := 0
var moving := 0
var held := 0

func observe(enemy: State, frame_us: int) -> void:
	if enemy.visual_packet_gap_ms > 0.0:
		gaps_seen += 1
		var gap_slot := reserve_slot(gaps, gaps_seen)
		if gap_slot >= 0:
			gaps[gap_slot] = enemy.visual_packet_gap_ms
	if enemy.visual_last_motion_us == 0 or frame_us - enemy.visual_last_motion_us > MOVEMENT_TAIL_US:
		return
	moving += 1
	held += int(enemy.visual_step_distance <= HOLD_DISTANCE)
	var slot := reserve_slot(steps, moving)
	if slot >= 0:
		if slot == errors.size():
			errors.append(0.0)
		steps[slot] = enemy.visual_step_distance * 100.0
		errors[slot] = enemy.visual_position.distance_to(enemy.position_xz) * 100.0

func reserve_slot(samples: Array[float], seen: int) -> int:
	if samples.size() < MAX_SAMPLES:
		samples.append(0.0)
		return samples.size() - 1
	var slot := rng.randi_range(0, seen - 1)
	return slot if slot < MAX_SAMPLES else -1

func summary() -> Dictionary:
	return {
		"moving_actor_frames": moving,
		"held_percent": 100.0 * held / moving if moving > 0 else null,
		"visible_motion_step_cm": percentiles(steps),
		"visible_to_snapshot_cm": percentiles(errors),
		"snapshot_spacing_ms": percentiles(gaps),
	}

func reset() -> void:
	frames.clear()
	gaps.clear()
	steps.clear()
	errors.clear()
	gaps_seen = 0
	moving = 0
	held = 0

static func percentiles(values: Array) -> Dictionary:
	if values.is_empty():
		return {}
	var ordered := values.duplicate()
	ordered.sort()
	var last := ordered.size() - 1
	return {"n": ordered.size(), "p50": ordered[roundi(last * 0.50)], "p95": ordered[roundi(last * 0.95)]}
