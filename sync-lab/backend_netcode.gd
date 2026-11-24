extends Node

const Orb = preload("res://orb.gd")
const SpawnerScene = preload("res://netcode_spawner.tscn")
const SPAWN_BATCH := 8
const SPAWN_WINDOW := 64
const SPAWN_PROGRESS_STEP := 32

var orbs: Array[Orb] = []
var _spawner: NetcodeSpawner
var _host := false
var _owned := 0
var _visible := 0
var _reported_progress := 0
var _last_seats := 0
var _next_spawn := 0
var _area := -1
var _ready_sent := false
var _open := false
var _error := ""

func open(pool: Node, host: bool, endpoint: String, count: int) -> String:
	var split := endpoint.rfind(":")
	if split <= 0 or not endpoint.substr(split + 1).is_valid_int():
		return "请输入有效的 IP 和端口"
	var ip := endpoint.left(split).trim_prefix("[").trim_suffix("]")
	var port := endpoint.substr(split + 1).to_int()
	_host = host
	orbs.resize(count)
	_spawner = SpawnerScene.instantiate()
	pool.add_child(_spawner)
	_spawner.spawned.connect(_register_orb)
	_spawner.despawned.connect(_unregister_orb)
	_spawner.spawn_failed.connect(_spawn_failed)
	Netcode.interest_exit.connect(_unregister_orb)
	Netcode.connection_failed.connect(_connection_failed)
	Netcode.room_left.connect(_room_left)
	var status: Error
	if host:
		var options := NetcodeRoomOptions.new()
		options.max_players = 2
		options.custom_properties = {"lab-size": count, "lab-area": 0, "lab-progress": 0, "lab-ready": 0}
		status = Netcode.create_room(ip, port, options)
	else:
		status = Netcode.join_room(ip, port)
	_open = status == OK
	return "" if _open else error_string(status)

func _register_orb(node: Node) -> void:
	if node is not Orb or node.index < 0 or node.index >= orbs.size():
		_error = "生成对象的首值缺少有效编号"
		return
	if not is_instance_valid(orbs[node.index]):
		_visible += 1
	orbs[node.index] = node

func _unregister_orb(node: Node) -> void:
	if node is Orb and node.index >= 0 and node.index < orbs.size() and orbs[node.index] == node:
		orbs[node.index] = null
		_visible -= 1

func _spawn_failed(node: Node, reason: String) -> void:
	_unregister_orb(node)
	_error = reason

func _connection_failed(reason: String) -> void:
	_error = reason

func _room_left() -> void:
	if _open: _error = "TCP 房间已关闭"

func advance() -> Dictionary:
	if not _error.is_empty(): return {"error": _error}
	var room := Netcode.get_room() as NetcodeRoomView
	if room == null: return {}
	var props := room.get_custom_properties()
	if int(props.get("lab-size", -1)) != orbs.size():
		return {"error": "两端选择的对象数必须相同"}
	var seats := room.get_player_count()
	var area := 0 if _host else int(props.get("lab-area", 0))
	if area != _area and (_host or _subscribe(area)): _area = area
	var now := Time.get_ticks_msec()
	var clock_ready := Netcode.is_simulation_ready()
	if seats == 2 and clock_ready and now >= _next_spawn:
		_next_spawn = now + 50
		var limit := int(props.get("lab-progress", 0)) + SPAWN_WINDOW
		_spawn_slice(mini(limit, orbs.size() - 1) if _host else 1)
	var player := Netcode.get_local_player_id()
	if _host and seats < 2 and _last_seats == 2:
		room.set_properties({"lab-ready": 0, "lab-area": 0, "lab-progress": 0})
	elif not _host and seats == 2 and clock_ready and not _ready_sent:
		if _visible == orbs.size() and writable(1):
			_ready_sent = room.set_property("lab-ready", player)
		elif _visible >= _reported_progress + SPAWN_PROGRESS_STEP:
			if room.set_property("lab-progress", _visible):
				_reported_progress = _visible
	_last_seats = seats
	var ready_player := int(props.get("lab-ready", 0))
	var ready := seats == 2 and clock_ready and ready_player > 0 and (_host or ready_player == player)
	return {"ready": true, "round": ready, "seats": seats, "player": player, "rtt": Netcode.get_rtt() * 1000.0,
		"queued": Netcode.get_transport_stats().get("queued_bytes", 0)}

func _spawn_slice(limit: int) -> void:
	var scenes := _spawner.spawnable_scenes
	for i in mini(SPAWN_BATCH, limit - _owned):
		var index := (0 if _owned == 0 else _owned + 1) if _host else 1
		var group := 0 if index < Orb.GLOBAL_COUNT else 1 + index % 2
		if _spawner.spawn(scenes[group], _initialize.bind(index)) == null:
			_error = "Netcode 生成请求未受理"
			return
		_owned += 1

func _initialize(_sync: NetcodeSharedReplicator, node: Orb, index: int) -> void:
	node.version = index + 1

func _subscribe(area: int) -> bool:
	for key in [1, 2]:
		var applied := Netcode.add_user_key(key) if area == 0 or area == key else Netcode.remove_user_key(key)
		if not applied: return false
	return true

func visible(i: int) -> bool:
	return is_instance_valid(orbs[i]) and not orbs[i].is_queued_for_deletion()

func writable(i: int) -> bool:
	return visible(i) and orbs[i].get_node("Sync").is_write_ready()

func set_area(next: int) -> bool:
	var room := Netcode.get_room() as NetcodeRoomView
	return _host and room != null and room.set_property("lab-area", next)

func trace_state() -> Dictionary:
	return {"network_time_s": Netcode.get_network_time(), "aoi": _area, "spawned_local": _owned}

func close() -> void:
	var opened := _open
	_open = false
	if Netcode.connection_failed.is_connected(_connection_failed):
		Netcode.connection_failed.disconnect(_connection_failed)
		Netcode.room_left.disconnect(_room_left)
		Netcode.interest_exit.disconnect(_unregister_orb)
	if opened: Netcode.leave_room()
