extends Control

const Orb = preload("res://orb.gd")
const NetcodeBackend = preload("res://backend_netcode.gd")
const FusionBackend = preload("res://backend_fusion.gd")
const SyncTrace = preload("res://sync_trace.gd")
const GLOBAL_COUNT := Orb.GLOBAL_COUNT
const OBJECT_COUNTS := [32, 64, 128, 512, 1024]
const DEFAULT_OBJECT_COUNT := 128
const PLAYER_WRITE_INTERVAL := 0.1
const LOAD_WARMUP_WAVES := 50
const REMOTE_AVATAR_DELAY_MS := 1500
const BACKEND_NAMES := ["Netcode", "Fusion"]
const GREEN := Color("5de2b1")
const CYAN := Color("6ebdff")
const GOLD := Color("ffc278")
const TEXT := Color("e9f3f7")
const MUTED := Color("a2b8c8")

class Arena extends Control:
	const CIRCLE_SIDES := 24
	const INSTANCE_FLOATS := 12

	var objects: Array[Orb] = []
	var configured := DEFAULT_OBJECT_COUNT
	var backend: Node
	var _circles: MultiMesh
	var _instances := PackedFloat32Array()
	var _circle_count := 0

	func _ready() -> void:
		var vertices := PackedVector2Array([Vector2.ZERO])
		var indices := PackedInt32Array()
		for side in CIRCLE_SIDES:
			vertices.append(Vector2.from_angle(TAU * side / CIRCLE_SIDES))
			indices.append(0)
			indices.append(side + 1)
			indices.append((side + 1) % CIRCLE_SIDES + 1)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_INDEX] = indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_circles = MultiMesh.new()
		_circles.transform_format = MultiMesh.TRANSFORM_2D
		_circles.use_colors = true
		_circles.mesh = mesh
		resized.connect(_resize_circle_bounds)
		_resize_circle_bounds()

	func _resize_circle_bounds() -> void:
		_circles.custom_aabb = AABB(Vector3(-16.0, -16.0, -1.0), Vector3(size.x + 32.0, size.y + 32.0, 2.0))

	func _draw() -> void:
		var bounds := Rect2(1, 1, size.x - 2, size.y - 2)
		draw_rect(bounds, Color("09131f"))
		draw_rect(bounds, Color("2d4052"), false, 1)
		var pad := 20.0
		var global_height := 78.0
		var lane_width := (size.x - pad * 3.0) * 0.5
		var lower_y := global_height + pad * 1.5
		var lane_height := maxf(40.0, size.y - lower_y - pad)
		var left := Rect2(pad, lower_y, lane_width, lane_height)
		var right := Rect2(pad * 2.0 + lane_width, lower_y, lane_width, lane_height)
		_lane(Rect2(pad, pad, size.x - pad * 2.0, global_height), "全局 · 玩家及公共对象", GREEN)
		_lane(left, "AOI 1", CYAN)
		_lane(right, "AOI 2", GOLD)
		var cols := mini(12 if configured <= 512 else 17, ceili((configured - GLOBAL_COUNT) / 2.0))
		var rows := ceili(float(configured - GLOBAL_COUNT) / (2 * cols))
		var stride := Vector2((lane_width - 18) / cols, (lane_height - 38) / rows)
		var radius := clampf(minf(stride.x, stride.y) * 0.26, 1.4, 6.6)
		var capacity := maxi(0, objects.size() - 2) * 2
		if _circles.instance_count != capacity:
			_circles.instance_count = capacity
			_instances.resize(capacity * INSTANCE_FLOATS)
		_circle_count = 0
		for i in range(2, objects.size()):
			var orb := objects[i]
			if not backend.visible(i): continue
			if i < GLOBAL_COUNT:
				var px := pad + 18.0 + (size.x - 2.0 * pad - 36.0) * (i - 2) / (GLOBAL_COUNT - 3.0)
				_orb(Vector2(px, pad + 54), minf(5.0, size.x / 115.0), GREEN, orb)
				continue
			@warning_ignore("integer_division")
			var index := (i - GLOBAL_COUNT) / 2
			var lane := left if i % 2 == 0 else right
			@warning_ignore("integer_division")
			var point := lane.position + Vector2(9, 31) + (Vector2(index % cols, index / cols) + Vector2(0.5, 0.5)) * stride
			point += orb.offset.limit_length() * stride * 0.33
			_orb(point, radius, CYAN if i % 2 == 0 else GOLD, orb)
		if _circle_count > 0:
			_circles.visible_instance_count = _circle_count
			_circles.buffer = _instances
			draw_multimesh(_circles, null)
		var play := bounds.grow(-32.0)
		for i in mini(2, objects.size()):
			var avatar := objects[i]
			if not is_instance_valid(avatar) or not backend.visible(i): continue
			var pos := play.position + ((avatar.offset + Vector2.ONE) * 0.5) * play.size
			var color := GREEN if i == 0 else Color("ff989f")
			draw_circle(pos, 16.0, Color(color, 0.22))
			draw_arc(pos, 13.0, 0, TAU, 24, color, 2.0, true)
			draw_circle(pos, 7.0, color)
			draw_string(get_theme_default_font(), pos + Vector2(17, 5), "A" if i == 0 else "B",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 17, TEXT)

	func _lane(rect: Rect2, caption: String, accent: Color) -> void:
		draw_rect(rect, Color(accent, 0.045))
		draw_rect(rect, Color(accent, 0.30), false, 1.0)
		draw_string(get_theme_default_font(), rect.position + Vector2(12, 22), caption,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, accent)

	func _orb(pos: Vector2, radius: float, color: Color, orb: Orb) -> void:
		if orb.active:
			_circle(pos, radius * 1.71, Color(color, 0.20))
		_circle(pos, radius, color.darkened(0.27 * (1.0 - orb.energy)))

	func _circle(pos: Vector2, radius: float, color: Color) -> void:
		# A 2D MultiMesh stores two padded transform rows followed by RGBA.
		var base := _circle_count * INSTANCE_FLOATS
		_instances[base] = radius
		_instances[base + 3] = pos.x
		_instances[base + 5] = radius
		_instances[base + 7] = pos.y
		_instances[base + 8] = color.r
		_instances[base + 9] = color.g
		_instances[base + 10] = color.b
		_instances[base + 11] = color.a
		_circle_count += 1

var _backend: Node
var _pool: Node
var _backend_picker: OptionButton
var _selected_backend := 0
var _addresses := ["127.0.0.1:43231", "sync-lab"]
var _orbs: Array[Orb] = []
var _arena: Arena
var _endpoint: LineEdit
var _count: OptionButton
var _host_button: Button
var _join_button: Button
var _leave_button: Button
var _pause_button: Button
var _aoi_button: Button
var _heading: Label
var _status: Label
var _stats: Label
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
	_build_ui()
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

func _build_ui() -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "Noto Sans CJK SC"])
	var skin := Theme.new()
	skin.default_font = font
	skin.default_font_size = 14
	for type in ["Button", "OptionButton", "LineEdit"]:
		for state in ["normal", "read_only", "disabled", "hover", "pressed", "focus"]:
			var style := StyleBoxFlat.new()
			style.bg_color = Color("25485b") if state in ["hover", "pressed", "focus"] else Color("162839")
			style.border_color = Color("37546b")
			style.set_border_width_all(1)
			style.set_corner_radius_all(5)
			style.content_margin_left = 11
			style.content_margin_right = 11
			style.content_margin_top = 6
			style.content_margin_bottom = 6
			skin.set_stylebox(state, type, style)
		skin.set_color("font_color", type, TEXT)
	theme = skin
	var margin := MarginContainer.new()
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]: margin.add_theme_constant_override("margin_" + side, 17)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 9)
	margin.add_child(body)
	var title := _row(body)
	_heading = _label(title, "同步试验场", 24, TEXT)
	_heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status = _label(title, "等待连接", 14, GREEN)
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var join := _row(body)
	_backend_picker = OptionButton.new()
	for backend_name in BACKEND_NAMES:
		_backend_picker.add_item(backend_name)
	_backend_picker.item_selected.connect(_select_backend)
	join.add_child(_backend_picker)
	_endpoint = LineEdit.new()
	_endpoint.placeholder_text = "主机地址:端口"
	_endpoint.text = _addresses[0]
	_endpoint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join.add_child(_endpoint)
	_count = OptionButton.new()
	for count in OBJECT_COUNTS:
		_count.add_item("%d 对象" % count, count)
	_count.select(OBJECT_COUNTS.find(DEFAULT_OBJECT_COUNT))
	_count.item_selected.connect(func(_index: int): _arena.configured = _count.get_selected_id())
	join.add_child(_count)
	_host_button = _button(join, "开房", _connect_room.bind(true))
	_join_button = _button(join, "加入", _connect_room.bind(false))
	_leave_button = _button(join, "退出", _close_room.bind("已退出房间"))
	_leave_button.disabled = true
	var controls := _row(body)
	_stats = _label(controls, "房间承载 2 名玩家", 13, MUTED)
	_stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pause_button = _button(controls, "暂停负载", _toggle_pause)
	_aoi_button = _button(controls, "客端 AOI：全部", _change_area)
	_pause_button.disabled = true
	_aoi_button.disabled = true
	_arena = Arena.new()
	_arena.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_arena.custom_minimum_size.y = 300
	body.add_child(_arena)
	_label(body, "WASD / 方向键移动  ·  房主可切换客端 AOI 和暂停负载  ·  负载对象 %.0f Hz" % (1.0 / PLAYER_WRITE_INTERVAL), 12, MUTED)

func _row(parent: Node) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	return row

func _label(parent: Node, content: String, height: int, tone: Color) -> Label:
	var label := Label.new()
	label.text = content
	label.add_theme_font_size_override("font_size", height)
	label.add_theme_color_override("font_color", tone)
	parent.add_child(label)
	return label

func _button(parent: Node, title: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = title
	button.pressed.connect(action)
	parent.add_child(button)
	return button

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
	_pool = Node.new()
	_pool.name = "ReplicatedOrbs"
	add_child(_pool)
	_backend = FusionBackend.new() if _selected_backend == 1 else NetcodeBackend.new()
	add_child(_backend)
	var error: String = _backend.open(_pool, host, endpoint, _arena.configured)
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
	if is_instance_valid(_pool):
		remove_child(_pool)
		_pool.queue_free()
		_pool = null
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
