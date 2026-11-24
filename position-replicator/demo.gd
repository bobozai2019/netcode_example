extends Node3D

@onready var vehicle = $Vehicle
@onready var headlight: Node3D = $Vehicle/Headlight
@onready var replicator = $Vehicle/PositionReplicator
var step := 0

const BEFORE := {".:position": Vector3(3, 0, 0), ".:steering": 0.0, "Headlight:visible": false}
const AFTER := {".:position": Vector3(4, 0, 0), ".:steering": 0.75, "Headlight:visible": true}

# World 的物理优先级为 -10，先于 replicator（默认 0）执行。
func _physics_process(_delta: float) -> void:
    step += 1
    if step == 2:
        vehicle.position = Vector3(4, 0, 0)
        vehicle.steering = 0.75
        headlight.visible = true
        print("Live after write: ", vehicle.position, ", ", vehicle.steering, ", ", headlight.visible)
        check_snapshot("Before capture", BEFORE)
    elif step == 3:
        if check_snapshot("After capture", AFTER):
            get_tree().quit()

func check_snapshot(label: String, expected: Dictionary) -> bool:
    var actual: Dictionary = replicator.get_sampled_values()
    print(label, ": ", actual)
    if actual == expected and replicator.get_sampled_position() == expected[".:position"]:
        return true
    push_error("Expected %s, got %s" % [expected, actual])
    get_tree().quit(1)
    return false
