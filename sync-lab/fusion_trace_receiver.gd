extends SceneTree

const SIDES := ["host", "guest"]

var _listeners: Array[TCPServer] = []
var _streams: Array[PacketPeerStream] = []
var _logs: Array[FileAccess] = []
var _next_sample := [0, 0]
var _attached := [false, false]
var _sample_paths := [{}, {}]
var _start_ms := 0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		quit(1)
		return
	_start_ms = Time.get_ticks_msec()
	var ports := {}
	for side in SIDES:
		var listener := TCPServer.new()
		var log_file := FileAccess.open(args[0].path_join(side + "-fusion.jsonl"), FileAccess.WRITE)
		if log_file == null or listener.listen(0, "127.0.0.1") != OK:
			quit(1)
			return
		var stream := PacketPeerStream.new()
		stream.input_buffer_max_size = 4 * 1024 * 1024
		_listeners.append(listener)
		_streams.append(stream)
		_logs.append(log_file)
		ports[side] = listener.get_local_port()
	var ready := FileAccess.open(args[1], FileAccess.WRITE)
	if ready == null:
		quit(1)
		return
	ready.store_line(JSON.stringify(ports))

func _process(_delta: float) -> bool:
	var now := Time.get_ticks_msec()
	var connected := 0
	for i in SIDES.size():
		var stream := _streams[i]
		if not _attached[i] and _listeners[i].is_connection_available():
			stream.stream_peer = _listeners[i].take_connection()
			_attached[i] = true
		if stream.stream_peer == null:
			continue
		var peer := stream.stream_peer as StreamPeerTCP
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			stream.stream_peer = null
			continue
		connected += 1
		var latest: Array = []
		for _packet in mini(stream.get_available_packet_count(), 64):
			var message = stream.get_var(false)
			if message is not Array or message.size() != 3 or message[2] is not Array:
				continue
			if message[0] == "fusion:stats":
				latest = message[2]
			elif message[0] == "sync_lab:watched_objects" and message[2].size() == 1 and message[2][0] is Dictionary:
				_sample_paths[i] = message[2][0]
		if not latest.is_empty() and now >= _next_sample[i]:
			_next_sample[i] = now + 1000
			_record(i, latest)
	if connected == 0 and ((_attached[0] and _attached[1]) or now - _start_ms > 90000):
		quit()
	return false

func _record(side: int, data: Array) -> void:
	if data.size() < 5 or data[4] is not Array:
		return
	var by_owner := {}
	var samples := {}
	for row in data[4]:
		if row is not Dictionary:
			continue
		var owner := str(row.get("owner", 0))
		if not by_owner.has(owner):
			by_owner[owner] = {"objects": 0, "sending": 0, "receiving": 0, "sent_Bps": 0.0, "recv_Bps": 0.0}
		var bucket: Dictionary = by_owner[owner]
		var sent := float(row.get("sent_bps", 0.0))
		var received := float(row.get("recv_bps", 0.0))
		bucket.objects += 1
		bucket.sending += int(sent > 0.0)
		bucket.receiving += int(received > 0.0)
		bucket.sent_Bps += sent
		bucket.recv_Bps += received
		var path := str(row.get("path", ""))
		if _sample_paths[side].has(path):
			var index: int = _sample_paths[side][path]
			samples[str(index)] = {"owner": owner, "sent_Bps": sent, "recv_Bps": received}
	_logs[side].store_line(JSON.stringify({"unix_ms": roundi(Time.get_unix_time_from_system() * 1000),
		"player": data[0], "master": data[1], "rtt_ms": data[2], "sdk_object_count": data[3],
		"owners": by_owner, "sample_objects": samples}))
	_logs[side].flush()
