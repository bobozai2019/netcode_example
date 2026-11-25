extends Node3D

const Rules = preload("res://combat/rules.gd")

@onready var rig: Node3D = $Rig
@onready var animation: AnimationPlayer = $Rig/AnimationPlayer
@onready var ring: MeshInstance3D = $Footprint
@onready var simplified_body: MeshInstance3D = $Simplified

var current := ""
var last_hp := 100
var react_until := 0
var initialized := false

func use_simplified_rig() -> void:
	rig.hide()
	animation.active = false
	simplified_body.show()

func present(motion, life, step: int, instant: bool, delta: float) -> void:
	var next := Rules.xz(motion.position_xz)
	position = next if instant or not initialized else position.lerp(next, 1.0 - exp(-21.0 * delta))
	initialized = true
	if rig.visible and motion.facing.length_squared() > 0.01:
		rig.rotation.y = lerp_angle(rig.rotation.y, atan2(motion.facing.x, motion.facing.y), 1.0 - exp(-25.0 * delta))
	if life.hp < last_hp:
		react_until = step + 24
	last_hp = life.hp
	ring.visible = life.hp > 0 and (step >= life.invulnerable_until or step % 8 < 5)
	if not animation.active:
		return
	var clip := "Idle"
	if life.hp <= 0:
		clip = "Death"
	elif step < react_until:
		clip = "HitReact"
	elif motion.velocity.length_squared() > 0.25:
		clip = "Run"
	if clip != current:
		animation.play(clip, 0.08)
		current = clip
