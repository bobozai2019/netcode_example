extends Node2D

@onready var spawner = $Spawner
@onready var setup := $UI/Setup
@onready var status := $UI/Status

func _ready() -> void:
    if not OS.get_cmdline_user_args().is_empty():
        _open_yard.call_deferred()

func _host_room() -> void:
    _connect_room(true)

func _join_room() -> void:
    _connect_room(false)

func _open_yard() -> void:
    get_tree().change_scene_to_file("res://yard/yard.tscn")

func _connect_room(host: bool) -> void:
    var error: String = spawner.open(host, %Address.text.strip_edges(), int(%Port.value))
    if not error.is_empty():
        status.text = error
        return
    setup.hide()
    %Leave.show()
    status.text = "正在连接…"

func _on_joined(player: int) -> void:
    var template: PackedScene = spawner.spawnable_scenes[%Model.selected]
    var vehicle = await spawner.spawn(template)
    if not vehicle:
        if %Leave.visible: status.text = "未能生成车辆"
        return
    vehicle.position = Vector2(155 + 65 * ((player - 1) % 8), 300)
    vehicle.local_driver = true
    status.text = "玩家 %d   ·   方向键或 WASD 驾驶" % player

func _on_closed(reason: String) -> void:
    setup.show()
    %Leave.hide()
    status.text = reason
