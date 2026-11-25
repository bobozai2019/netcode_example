extends MeshInstance3D

const Rules = preload("res://combat/rules.gd")

enum Paint { KNIFE, WARNING, WARNING_FILL, DANGER, DANGER_FILL, HALO, HIT, FALL, LIGHTNING }

@export var line_mesh: BoxMesh
@export var ring_mesh: TorusMesh
@export var paints: Array[StandardMaterial3D]

func line(from: Vector2, to: Vector2, width: float, height: float, tint: Paint) -> void:
	mesh = line_mesh
	material_override = paints[tint]
	var ray := to - from
	position = Rules.xz((from + to) * 0.5, height)
	rotation.y = atan2(ray.x, ray.y)
	scale = Vector3(width, 0.055, maxf(0.06, ray.length()))
	show()

func ring(point: Vector2, radius: float, height: float, tint: Paint) -> void:
	mesh = ring_mesh
	material_override = paints[tint]
	position = Rules.xz(point, height)
	rotation.y = 0
	scale = Vector3(radius, 0.46, radius)
	show()
