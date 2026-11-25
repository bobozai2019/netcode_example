extends Control

const Orb = preload("res://orb.gd")
const FusionBackend = preload("res://backend_fusion.gd")
const Arena = preload("res://arena.gd")
const SyncTrace = preload("res://sync_trace.gd")
const GLOBAL_COUNT := Orb.GLOBAL_COUNT
const NetcodeSessionScene = preload("res://netcode_session.tscn")
const PLAYER_WRITE_INTERVAL := 0.1
const LOAD_WARMUP_WAVES := 50
const REMOTE_AVATAR_DELAY_MS := 1500
const BACKEND_NAMES := ["Netcode", "Fusion"]
const GOLD := Color("ffc278")

@onready var _arena: Arena = %Arena
@onready var _backend_picker: OptionButton = %BackendPicker
@onready var _endpoint: LineEdit = %Endpoint
@onready var _count: OptionButton = %ObjectCount
@onready var _host_button: Button = %Host
@onready var _join_button: Button = %Join
@onready var _leave_button: Button = %Leave
@onready var _pause_button: Button = %Pause
@onready var _aoi_button: Button = %Aoi
@onready var _heading: Label = %Heading
@onready var _status: Label = %Status
@onready var _stats: Label = %Stats

var _backend: Node
var _selected_backend := 0
var _addresses := ["127.0.0.1:43231", "sync-lab"]
var _orbs: Array[Orb] = []
var _host := false
var _open := false
var _round := false
var _player := 0
var _aoi := 0
var _paused := false
var _local_point := Vector2.ZERO
var _manual := false
var _wave := 0
var _accumulator := 0.0
var _load_credit := 0.0
var _load_cursor := 2
var _stats_elapsed := 0.0
var _steps := 0
var _last_report := 0
var _saw_peer := false
var _stats_mark := 0
var _capture_path := ""
var _demo_check := false
var _join_deadline := 0
var _draw_after := 0
var _host_ready_path := ""
var _marked_ready := false
var _demo_start_wave := -1
var _demo_settled_wave := -1
var _demo_area_phase := 0
var _settled_area := -1
var _demo_visibility_path := ""
var _fields_reported := false
var _verified_fields := PackedByteArray()
var _verified_count := 0
var _next_flow_report := 0
var _trace_requested := false
var _trace: SyncTrace

func _ready() -> void:
	get_window().min_size = Vector2i(680, 480)
	var args := OS.get_cmdline_user_args()
	var backend := _argument(args, "--backend")
	if backend.is_empty():
		backend = str(ProjectSettings.get_setting("sync_lab/default_backend", "netcode"))
	if backend.to_lower() == "fusion":
		_backend_picker.select(1)
		_select_backend(1)
	var address := _argument(args, "--endpoint")
	if not address.is_empty(): _endpoint.text = address
	var object_count := _argument(args, "--objects").to_int()
	for i in _count.item_count:
		if _count.get_item_id(i) == object_count: _count.select(i)
	_arena.configured = _count.get_selected_id()
	_capture_path = _argument(args, "--capture")
	_host_ready_path = _argument(args, "--host-ready")
	_demo_check = "--demo-check" in args
	_trace_requested = "--trace" in args
	_demo_visibility_path = _argument(args, "--demo-visibility")
	if "--host" in args: _connect_room.call_deferred(true)
	elif "--join" in args: _connect_room.call_deferred(false)

func _argument(args: PackedStringArray, key: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else ""

func _select_object_count(index: int) -> void:
	_arena.configured = _count.get_item_id(index)

func _select_backend(index: int) -> void:
	_addresses[_selected_backend] = _endpoint.text
	_selected_backend = index
	_endpoint.placeholder_text = "Photon 房间名" if index == 1 else "主机地址:端口"
	_endpoint.text = _addresses[index]
	_status.text = "%s · 等待连接" % _connection_label()

func _connection_label() -> String:
	return FusionBackend.connection_label() if _selected_backend == 1 else "TCP 直连"

func _connect_room(host: bool) -> void:
	if _open:
		return
	var endpoint := _endpoint.text.strip_edges()
	if endpoint.is_empty():
		_status.text = "请输入 Photon 房间名" if _selected_backend == 1 else "请输入地址:端口"
		return
	_host = host
	_arena.configured = _count.get_selected_id()
	var session_scene := NetcodeSessionScene
	if _selected_backend == 1:
		if not Engine.has_singleton("Fusion"):
			_close_room("Fusion 扩展未加载")
			return
		session_scene = load("res://fusion_session.tscn")
		if session_scene == null:
			_close_room("无法加载 Fusion 会话场景")
			return
	_backend = session_scene.instantiate()
	add_child(_backend)
	var error: String = _backend.open(host, endpoint, _arena.configured)
	if not error.is_empty():
		_close_room(error)
		return
	_orbs = _backend.orbs
	if _trace_requested:
		_trace = SyncTrace.new(_orbs.size())
	if _demo_check:
		_verified_fields.resize(_orbs.size())
	_arena.objects = _orbs
	_arena.backend = _backend
	_open = true
	_backend_picker.disabled = true
	_endpoint.editable = false
	_count.disabled = true
	_join_button.disabled = true
	_host_button.disabled = true
	_leave_button.disabled = false
	_pause_button.visible = host
	_aoi_button.visible = host
	_join_deadline = Time.get_ticks_msec() + (42000 if _selected_backend == 1 else 12000)
	_heading.text = "房主 A · 同步试验场" if host else "客户端 B · 同步试验场"
	var link := _connection_label()
	get_window().title = "%s · %s" % ["A 房主" if host else "B 客户端", link]
	_status.text = "正在连接 %s" % link if _selected_backend == 1 else ("等待客人加入" if host else "正在加入房间")
	print("SYNC_LAB_OPEN backend=", BACKEND_NAMES[_selected_backend], " endpoint=", endpoint, " host=", host)
	if host and _selected_backend == 0:
		_mark_room_ready()

func _mark_room_ready() -> void:
	if _marked_ready:
		return
	_marked_ready = true
	print("SYNC_LAB_ROOM backend=", BACKEND_NAMES[_selected_backend], " host=", _host)
	_write_host_startup("ready")

func _write_host_startup(result: String) -> void:
	if _host and not _host_ready_path.is_empty():
		var ready := FileAccess.open(_host_ready_path, FileAccess.WRITE)
		if ready:
			ready.store_line(result)

func _close_room(message: String) -> void:
	if not _marked_ready:
		_write_host_startup("failed")
	if is_instance_valid(_backend):
		_backend.close()
		remove_child(_backend)
		_backend.queue_free()
		_backend = null
	_orbs = []
	_arena.objects = []
	_arena.backend = null
	_open = false
	_round = false
	_player = 0
	_saw_peer = false
	_marked_ready = false
	_demo_start_wave = -1
	_demo_settled_wave = -1
	_demo_area_phase = 0
	_settled_area = -1
	_fields_reported = false
	_verified_fields.clear()
	_verified_count = 0
	_stats_mark = 0
	_wave = 0
	_manual = false
	_paused = false
	_aoi = 0
	_accumulator = 0.0
	_load_credit = 0.0
	_load_cursor = 2
	_next_flow_report = 0
	_trace = null
	_stats_elapsed = 0.0
	_steps = 0
	_last_report = 0
	_status.text = message
	_stats.text = "房间承载 2 名玩家"
	_stats.modulate = Color.WHITE
	_pause_button.text = "暂停负载"
	_aoi_button.text = "客端 AOI：全部"
	_backend_picker.disabled = false
	_endpoint.editable = true
	_count.disabled = false
	_join_button.disabled = false
	_host_button.disabled = false
	_leave_button.disabled = true
	_pause_button.disabled = true
	_aoi_button.disabled = true
	_pause_button.show()
	_aoi_button.show()
	_heading.text = "同步试验场"
	get_window().title = "Godot 同步压测"
	_arena.queue_redraw()
	print("SYNC_LAB_CLOSED ", message)

func _process(dt: float) -> void:
	if not _open:
		return
	if _trace != null:
		_trace.record_frame()
	var frame: Dictionary = _backend.advance()
	var now := Time.get_ticks_msec()
	if frame.has("error"):
		_close_room(frame.error)
		return
	if frame.get("ready", false):
		_mark_room_ready()
	if not _marked_ready and not _round and now >= _join_deadline:
		_close_room("加入超时，请检查连接和房间")
		return
	if frame.is_empty():
		return
	_round = frame.round
	_player = int(frame.player)
	var seats := int(frame.seats)
	var link := _connection_label()
	if _host:
		_status.text = "%s · %d / 2" % [link, seats]
		if seats == 2 and not _round:
			_status.text += " · 同步初始对象"
		_pause_button.disabled = not _round
		_aoi_button.disabled = seats < 2 or not _round
	elif _marked_ready or _round:
		_status.text = "%s · 玩家 %d" % [link, _player]
		if not _round:
			_status.text += " · 同步初始对象"
	if _round and _wave < LOAD_WARMUP_WAVES:
		_status.text += " · 负载预热"
	if now >= _draw_after:
		_draw_after = now + 32
		_arena.queue_redraw()
	_stats_elapsed += dt
	if _stats_elapsed >= 0.28:
		_refresh_stats(frame)

func _physics_process(dt: float) -> void:
	if not _round:
		return
	_steps += 1
	var axis := Vector2(
		float(Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT)),
		float(Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN)) - float(Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP)))
	var index := 0 if _host else 1
	if not _endpoint.has_focus() and not axis.is_zero_approx() and _backend.writable(index):
		if not _manual:
			_local_point = _orbs[index].offset
		_manual = true
		_local_point = (_local_point + axis.normalized() * dt * 0.9).clamp(-Vector2.ONE, Vector2.ONE)
	_accumulator += dt
	if _accumulator >= PLAYER_WRITE_INTERVAL:
		_accumulator = fmod(_accumulator, PLAYER_WRITE_INTERVAL)
		_wave += 1
		var writable: bool = _backend.writable(index)
		if writable:
			var own := _orbs[index]
			var stamp := roundi(Time.get_unix_time_from_system() * 1000)
			own.publish(_wave, _local_point if _manual else own.deterministic_point(_wave), stamp)
		if _trace != null:
			_trace.written(index, writable)
		if _host and _demo_check and _saw_peer:
			_advance_demo_aoi()
	if _host and not _paused and _wave >= LOAD_WARMUP_WAVES:
		_write_load(dt)

func _write_load(dt: float) -> void:
	var count := _orbs.size() - 2
	_load_credit += count * dt / PLAYER_WRITE_INTERVAL
	var writes := mini(count, int(_load_credit))
	_load_credit -= writes
	if writes == 0:
		return
	var stamp := roundi(Time.get_unix_time_from_system() * 1000)
	for _write in writes:
		var writable: bool = _backend.writable(_load_cursor)
		if writable:
			var orb := _orbs[_load_cursor]
			orb.publish(_wave, orb.deterministic_point(_wave), stamp)
		if _trace != null:
			_trace.written(_load_cursor, writable)
		_load_cursor += 1
		if _load_cursor == _orbs.size():
			_load_cursor = 2

func _advance_demo_aoi() -> void:
	if _demo_visibility_path.is_empty():
		if _wave == _demo_start_wave + 24: _set_area(1)
		elif _wave == _demo_start_wave + 68: _set_area(2)
		elif _wave == _demo_start_wave + 112:
			_set_area(0)
		return
	if not FileAccess.file_exists(_demo_visibility_path):
		return
	var progress := FileAccess.get_file_as_string(_demo_visibility_path).strip_edges().split(",")
	if progress.size() != 3:
		return
	var guest_visible := progress[0].to_int()
	var guest_verified := progress[1] == "1"
	var guest_area := progress[2].to_int()
	if _demo_start_wave < 0 and guest_visible == _orbs.size() and guest_verified:
		_demo_start_wave = _wave
	if _demo_start_wave < 0:
		return
	if _demo_area_phase == 0 and _wave >= _demo_start_wave + 24:
		_set_area(1)
		_demo_area_phase = 1
	elif _demo_area_phase in [1, 2] and guest_area == _demo_area_phase:
		if _demo_settled_wave < 0:
			_demo_settled_wave = _wave
		if _wave - _demo_settled_wave >= 32:
			_set_area(2 if _demo_area_phase == 1 else 0)
			_demo_area_phase += 1
			_demo_settled_wave = -1

func _refresh_stats(frame: Dictionary) -> void:
	var active := 0
	var now := roundi(Time.get_unix_time_from_system() * 1000)
	var ages := PackedInt32Array()
	for i in _orbs.size():
		var orb := _orbs[i]
		if not _backend.visible(i): continue
		active += 1
		if orb.sent_at > 0 and (i == 1 if _host else i != 1):
			ages.append(maxi(0, now - orb.sent_at))
	ages.sort()
	var sync_age := ages[ceili(ages.size() * 0.95) - 1] if not ages.is_empty() else 0
	var clock := Time.get_ticks_usec()
	var hz := _steps * 1000000.0 / (clock - _stats_mark) if _stats_mark else 0.0
	_stats_mark = clock
	_steps = 0
	_stats_elapsed = 0
	var queue := "%.1f KiB" % (float(frame.queued) / 1024.0) if frame.has("queued") else "—"
	_stats.text = "%d/%d 对象 · %d FPS · %.0f 步/s · RTT %.0f ms · 年龄 P95 %d ms · 队列 %s" % [
		active, _orbs.size(), Engine.get_frames_per_second(), hz, float(frame.rtt), sync_age, queue]
	var remote_index := 1 if _host else 0
	var remote_stamp := _orbs[remote_index].sent_at if _backend.visible(remote_index) else 0
	var remote_age := maxi(0, now - remote_stamp) if remote_stamp > 0 else 0
	var load_cycle_ms := ceili(PLAYER_WRITE_INTERVAL * 1000.0)
	var delayed := remote_age > REMOTE_AVATAR_DELAY_MS or sync_age > load_cycle_ms + 2000
	_stats.modulate = GOLD if delayed else Color.WHITE
	if delayed:
		_stats.text += " · 远端更新滞后"
	if _trace != null:
		var session := {"backend": BACKEND_NAMES[_selected_backend], "player": _player, "wave": _wave,
			"round": _round, "paused": _paused, "visible": active, "sampled": ages.size(),
			"age_p95_ms": sync_age, "avatar_age_ms": remote_age, "rtt_ms": frame.rtt,
			"queued_bytes": frame.get("queued"), "physics_hz": hz, "aoi": _aoi,
			"requested_aoi": _aoi if _host else null}
		session.merge(_backend.trace_state(), true)
		_trace.sample(_backend, _orbs, _host, session)
	var ticks := Time.get_ticks_msec()
	if _demo_check and _round and ticks >= _next_flow_report and _backend.visible(remote_index):
		_next_flow_report = ticks + 1000
		print("SYNC_LAB_FLOW local_wave=%d remote_wave=%d visible=%d sampled=%d age_p95_ms=%d avatar_age_ms=%d" % [
			_wave, _orbs[remote_index].version >> 34, active, ages.size(), sync_age, remote_age])
	if not _saw_peer and _backend.visible(remote_index) and _orbs[remote_index].sent_at > 0 and active == _orbs.size():
		_saw_peer = true
		if not _host or _demo_visibility_path.is_empty():
			_demo_start_wave = _wave
		print("SYNC_LAB_LINKED player=%d visible=%d remote_version=%d" % [_player, active, _orbs[remote_index].version])
	if _demo_check and not _fields_reported: _verify_demo_fields()
	if _demo_check and not _host and active != _last_report and active > 0:
		_last_report = active
		print("SYNC_LAB_VISIBLE ", active)
	if _demo_check and not _host:
		_write_demo_visibility(active)
	if not _capture_path.is_empty() and _saw_peer and _wave >= 70:
		var path := _capture_path
		_capture_path = ""
		_capture(path)

func _verify_demo_fields() -> bool:
	for i in _orbs.size():
		if _verified_fields[i] or not (i == 1 if _host else i != 1) or not _backend.visible(i):
			continue
		var orb := _orbs[i]
		if orb.matches(orb.version >> 34):
			_verified_fields[i] = 1
			_verified_count += 1
	var expected := 1 if _host else _orbs.size() - 1
	if _verified_count != expected:
		return false
	_fields_reported = true
	print("SYNC_LAB_FIELDS ", _verified_count, "/", expected)
	return true

func _write_demo_visibility(active: int) -> void:
	if _demo_visibility_path.is_empty():
		return
	var area := int(_backend.trace_state().aoi)
	if area < 0: return
	for i in _orbs.size():
		var expected := i < GLOBAL_COUNT or area == 0 or area == 1 + i % 2
		if _backend.visible(i) != expected: return
	if _settled_area != area:
		_settled_area = area
		print("SYNC_LAB_AREA_SETTLED area=%d visible=%d" % [area, active])
	var visibility := FileAccess.open(_demo_visibility_path, FileAccess.WRITE)
	if visibility:
		visibility.store_line("%d,%d,%d" % [active, int(_fields_reported), area])

func _toggle_pause() -> void:
	_paused = not _paused
	_pause_button.text = "继续负载" if _paused else "暂停负载"

func _change_area() -> void:
	_set_area((_aoi + 1) % 3)

func _set_area(next: int) -> void:
	if not _host or not _round: return
	if not _backend.set_area(next):
		_status.text = "客人尚未就绪"
		return
	_aoi = next
	_aoi_button.text = "客端 AOI：%s" % ("全部" if next == 0 else str(next))
	print("SYNC_LAB_AOI ", next)

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)

func _exit_tree() -> void:
	if is_instance_valid(_backend):
		_backend.close()
