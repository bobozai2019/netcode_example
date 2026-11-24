extends Control

const Room = preload("res://addons/netcode/scene_room.gd")
var host := Room.new()
var guest := Room.new()
@onready var host_panel = $Host/Panel
@onready var guest_panel = $Guest/Panel
var claim_pending := false

func _ready() -> void:
	var listener := TCPServer.new()
	if listener.listen(0, "127.0.0.1") != OK:
		_show_error("无法分配本机端口")
		return
	var port := listener.get_local_port()
	listener.stop()
	host_panel.session = host
	guest_panel.session = guest
	var error := host.open($Host, true, "127.0.0.1", port, 2)
	if error.is_empty():
		error = guest.open($Guest, false, "127.0.0.1", port, 2)
	if not error.is_empty():
		_show_error(error)

func _process(_delta: float) -> void:
	var frame := host.advance()
	if frame.is_empty():
		return
	for event in frame.events:
		if event.kind == 5:
			host.game.answer(event, true)
	if not frame.round and frame.seats == 2 and host.game.start():
		if not host.spawn(host_panel.get_node("Network/Sync")):
			_show_error("创建同步对象失败")
			return
	var guest_frame := guest.advance()
	for event in guest_frame.get("events", []):
		if event.kind == 6:
			claim_pending = false
	var host_sync = host_panel.get_node("Network/Sync")
	var guest_sync = guest_panel.get_node("Network/Sync")
	if not host_sync.initialized or not guest_sync.initialized:
		return
	var writer: String = "玩家" if guest_sync.has_authority() else "房主"
	%Status.text = "本机已连接    ·    当前写者　" + writer
	%HostValues.text = _values("房主", host_panel)
	%GuestValues.text = _values("玩家", guest_panel)
	%Add.disabled = _writer() == null
	%Lamp.disabled = %Add.disabled
	%Claim.disabled = claim_pending or guest_sync.has_authority()
	%Send.disabled = false

func _values(label: String, panel: Node) -> String:
	return "%s    分数 %d    指示灯 %s    标记位置 %d    RPC %d 次" % [
		label, panel.score, "亮" if panel.get_node("Indicators/Lamp").visible else "灭",
		panel.get_node("Mechanism/Marker").position.x, panel.local_calls.size()]

func _writer() -> Node:
	if guest_panel.get_node("Network/Sync").is_write_ready(): return guest_panel
	if host_panel.get_node("Network/Sync").is_write_ready(): return host_panel
	return null

func _add_score() -> void:
	var writer := _writer()
	if writer:
		writer.score += 1
		writer.get_node("Mechanism/Marker").position.x += 1

func _toggle_lamp() -> void:
	var writer := _writer()
	if writer:
		var lamp := writer.get_node("Indicators/Lamp") as Node2D
		lamp.visible = not lamp.visible

func _claim() -> void:
	claim_pending = guest.game.claim(guest_panel.get_node("Network/Sync").object_id)

func _send_rpc() -> void:
	guest.rpc(guest_panel.pulse, guest_panel.local_calls.size() + 1)

func _show_error(message: String) -> void:
	%Status.text = message
	set_process(false)
	push_error(message)

func _exit_tree() -> void:
	guest.close()
	host.close()
