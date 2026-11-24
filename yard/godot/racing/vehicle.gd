extends Node2D

@export var speed := 190.0
var braking := false
var local_driver := false

func _physics_process(delta: float) -> void:
    if local_driver and $Sync.is_write_ready():
        var throttle := Input.get_axis("drive_reverse", "drive_forward")
        rotation += Input.get_axis("drive_left", "drive_right") * delta * 2.8 * signf(throttle)
        position += Vector2.RIGHT.rotated(rotation) * throttle * speed * delta
        position = position.clamp(Vector2(24, 154), Vector2(936, 610))
        braking = throttle < 0
    $BrakeLight.visible = braking
