extends MultiMeshInstance3D

@export var tint := Color.WHITE
@export var simplified_mesh: Mesh

func _ready() -> void:
	# The headless renderer cannot duplicate an allocated MultiMesh buffer.
	if DisplayServer.get_name() != "headless":
		multimesh = multimesh.duplicate()

func use_simplified_mesh() -> void:
	multimesh.mesh = simplified_mesh
