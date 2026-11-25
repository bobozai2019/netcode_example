extends Node

const Orb = preload("res://orb.gd")
const SPAWN_BATCH := 8
const SPAWN_INTERVAL_MS := 80
const SPAWN_WINDOW := 64
const SPAWN_PROGRESS_STEP := 32

var orbs: Array[Orb] = []
var _fusion: Object
@onready var _spawner: Node = $FusionSpawner
var _host := false
var _room_name := ""
var _next_owned := 0
var _next_spawn_at := 0
var _visible_count := 0
var _last_seats := 0
var _reported_progress := 0
var _guest_ready_sent := false
var _area := -1
var _clock_deadline := 0
var _clock_ready := false
var _retry_after := 0
var _retried_connection := false
var _error := ""
var _joined := false
var _started := false

static func connection_label() -> String:
	return "Photon Local" if int(ProjectSettings.get_setting("fusion/connection/mode", 0)) == 1 else "Photon Cloud"

func open(host: bool, endpoint: String, count: int) -> String:
	_fusion = Engine.get_singleton("Fusion")
	if _fusion.get_configured_app_id().is_empty():
		return "请在项目设置 → Fusion → Connection 填写 App ID"
	_host = host
	_room_name = endpoint
	orbs.resize(count)
	_fusion.connection_failed.connect(_on_failed)
	_fusion.connected_to_photon.connect(_on_connected)
	_fusion.room_joined.connect(_on_joined)
	_fusion.room_left.connect(_on_left)
	_started = true
	_connect()
	return ""

func _connect() -> void:
	_fusion.connect_to_photon("sync-lab-%d" % randi())

func _on_failed(reason: String) -> void:
	if not _joined and not _retried_connection and "1040" in reason:
		_retried_connection = true
		_retry_after = Time.get_ticks_msec() + 1000
		print("SYNC_LAB_FUSION_RETRY ", reason)
		return
	_error = "%s 连接失败 · %s" % [connection_label(), reason]

func _on_connected() -> void:
	_retry_after = 0
	if _host:
		var options = ClassDB.instantiate("FusionRoomOptions")
		options.set_max_players(2)
		options.set_is_visible(false)
		options.set_custom_properties({"lab-size": orbs.size(), "lab-area": 0, "lab-ready": 0, "lab-progress": 0})
		_fusion.join_or_create_room(_room_name, options)
	else:
		_fusion.join_room(_room_name)

func _on_joined() -> void:
	_joined = true
	_clock_deadline = Time.get_ticks_msec() + 18000

func _on_left() -> void:
	_error = "已离开 Photon 房间"

func _track_orb(node: Node) -> void:
	if node is not Orb:
		return
	if node.index >= 0:
		_register_orb(node)
	else:
		node.identified.connect(_register_orb, CONNECT_ONE_SHOT)

func _register_orb(orb: Orb) -> void:
	if orb.index >= 0 and orb.index < orbs.size():
		if not is_instance_valid(orbs[orb.index]):
			_visible_count += 1
		orbs[orb.index] = orb

func _untrack_orb(node: Node) -> void:
	if node is Orb and node.index >= 0 and node.index < orbs.size() and orbs[node.index] == node:
		orbs[node.index] = null
		_visible_count -= 1

func advance() -> Dictionary:
	if not _error.is_empty():
		return {"error": _error}
	var now := Time.get_ticks_msec()
	if _retry_after > 0 and now >= _retry_after:
		_retry_after = 0
		_connect()
	if not _joined:
		return {}
	var session = _fusion.get_room()
	if not is_instance_valid(session):
		return {"error": "已离开 Photon 房间"}
	var options: Dictionary = session.get_custom_properties()
	if int(options.get("lab-size", orbs.size())) != orbs.size():
		return {"error": "两端选择的对象数必须相同"}
	var seats: int = session.get_player_count()
	var area := 0 if _host else int(options.get("lab-area", 0))
	if area != _area:
		_subscribe(area)
	if not _clock_ready and float(_fusion.get_network_time()) > 0.0:
		_clock_ready = true
		print("SYNC_LAB_FUSION_CLOCK player=", _fusion.get_local_player_id())
	if not _clock_ready and now >= _clock_deadline:
		return {"error": "已加入 Photon 房间，Fusion 仿真握手超时"}
	if seats == 2 and _clock_ready and now >= _next_spawn_at:
		_next_spawn_at = now + SPAWN_INTERVAL_MS
		var guest_progress := int(options.get("lab-progress", 0))
		var limit := SPAWN_WINDOW + guest_progress if _host else 1
		_spawn_slice(limit)
	var player: int = _fusion.get_local_player_id()
	if _host and seats < 2 and _last_seats == 2:
		session.set_properties({"lab-ready": 0, "lab-area": 0, "lab-progress": 0})
	elif not _host and seats == 2 and _clock_ready and not _guest_ready_sent:
		if _visible_count == orbs.size():
			_guest_ready_sent = session.set_property("lab-ready", player)
		elif _visible_count >= _reported_progress + SPAWN_PROGRESS_STEP:
			if session.set_property("lab-progress", _visible_count):
				_reported_progress = _visible_count
	_last_seats = seats
	var ready_player := int(options.get("lab-ready", 0))
	var round_ready := seats == 2 and _clock_ready and ready_player > 0 and (_host or ready_player == player)
	return {"ready": true, "round": round_ready, "seats": seats,
			"player": player, "rtt": float(_fusion.get_rtt()) * 1000.0}

func _spawn_slice(limit: int) -> void:
	var capacity := mini(orbs.size() - 1, limit) if _host else 1
	for n in mini(SPAWN_BATCH, capacity - _next_owned):
		var index := 1
		if _host:
			index = 0 if _next_owned == 0 else _next_owned + 1
		var group := 0 if index < Orb.GLOBAL_COUNT else 1 + index % 2
		var actor: Orb = _spawner.spawn(_spawner.get_spawnable_scene(group), _initialize_orb.bind(index))
		if not is_instance_valid(actor):
			_error = "Fusion 生成对象失败"
			return
		if actor.index != index:
			_error = "Fusion 生成回调未安装初始编号"
			return
		_register_orb(actor)
		_next_owned += 1

func _initialize_orb(_sync: Node, node: Orb, index: int) -> void:
	node.version = index + 1

func _subscribe(area: int) -> void:
	for key in [1, 2]:
		if area == 0 or area == key:
			_fusion.add_user_key(key)
		else:
			_fusion.remove_user_key(key)
	_area = area

func visible(i: int) -> bool:
	return is_instance_valid(orbs[i]) and not orbs[i].is_queued_for_deletion()

func writable(i: int) -> bool:
	return visible(i) and orbs[i].get_node("Sync").has_authority()

func set_area(next: int) -> bool:
	if not _host or not _joined:
		return false
	var session = _fusion.get_room()
	return is_instance_valid(session) and session.set_property("lab-area", next)

func trace_state() -> Dictionary:
	return {"network_time_s": _fusion.get_network_time(), "aoi": _area,
		"connection_status": _fusion.get_connection_status(), "spawned_local": _next_owned}

func close() -> void:
	if not _started:
		return
	_started = false
	_fusion.connection_failed.disconnect(_on_failed)
	_fusion.connected_to_photon.disconnect(_on_connected)
	_fusion.room_joined.disconnect(_on_joined)
	_fusion.room_left.disconnect(_on_left)
	_fusion.disconnect_from_photon()
