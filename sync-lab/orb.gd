extends Node2D

signal identified(orb)

const GLOBAL_COUNT := 24
const FLOAT_STEP := 0.01
const VECTOR_STEP := Vector2(FLOAT_STEP, FLOAT_STEP)

var index := -1
var version := 0:
	set(value):
		version = value
		if index < 0 and value > 0:
			index = int((value - 1) & 0xffffffff)
			identified.emit(self)
var energy := 0.0
var active := false
var label := ""
var offset := Vector2.ZERO
var trail := PackedInt32Array()
var tags := PackedFloat32Array()
var sent_at := 0

func publish(wave: int, point: Vector2, clock: int) -> void:
	version = (wave << 34) + index + 1
	energy = _energy_for(wave)
	active = (wave + index) % 4 == 0
	label = "%d/%d" % [index, wave]
	offset = point.snapped(VECTOR_STEP)
	trail = PackedInt32Array([index, wave, -wave])
	tags = PackedFloat32Array([index, wave])
	sent_at = clock

func deterministic_point(wave: int) -> Vector2:
	if index < 2:
		var angle := wave * 0.035 + PI * index
		return Vector2(cos(angle) * 0.72, sin(angle) * 0.55)
	var phase := wave * 0.27 + index * 0.34
	return Vector2(cos(phase), sin(phase))

func _energy_for(wave: int) -> float:
	return snappedf(0.5 + 0.5 * sin(wave * 0.4 + index), FLOAT_STEP)

func matches(wave: int) -> bool:
	return version == (wave << 34) + index + 1 and sent_at > 0 \
		and is_equal_approx(energy, _energy_for(wave)) \
		and active == ((wave + index) % 4 == 0) and label == "%d/%d" % [index, wave] \
		and offset.is_equal_approx(deterministic_point(wave).snapped(VECTOR_STEP)) \
		and trail == PackedInt32Array([index, wave, -wave]) and tags == PackedFloat32Array([index, wave])
