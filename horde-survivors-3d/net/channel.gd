
extends Node

signal message(sender: int, code: int, fields: PackedInt32Array)
signal movement(sender: int, run_id: int, sequence: int, axis: Vector2)

enum Code {
	READY, START, ATTACK, HIT, OWNER_HIT, COMMIT, RECEIPT, DANGER, CLAIM, PICKUP,
	CHOOSE, UPGRADE, END, WRITABLE, BENCH_DRAINED, BENCH_DONE, CHAIN,
	BENCH_CLOCK_REQUEST, BENCH_CLOCK_REPLY,
}
const MAX_FIELDS := 48
const IN_FLIGHT := 48
const RECEIVE_WINDOW := 4096
var sent := 0
var received := 0
var rejected := 0
var message_us := 0
var queue: Array[Dictionary] = []
var queue_head := 0
var inflight: Array[Dictionary] = []
var next_sequence := 0
var next_receive := 1
var buffered: Dictionary[int, Dictionary] = {}
var queue_peak := 0
var peer := 0

func _enter_tree() -> void:
	Netcode.register_broadcast_receiver(self)

func _exit_tree() -> void:
	Netcode.unregister_broadcast_receiver(self)

func send(recipient: int, code: int, fields: PackedInt32Array) -> void:
	assert(fields.size() <= MAX_FIELDS)
	if recipient == Netcode.get_local_player_id():
		message.emit(recipient, code, fields)
		return
	if peer == 0 or (recipient != 0 and recipient != peer):
		return
	next_sequence += 1
	queue.append({"sequence": next_sequence, "code": code, "bytes": fields.to_byte_array()})
	queue_peak = maxi(queue_peak, backlog())

func set_peer(player: int) -> void:
	if peer == player:
		return
	peer = player
	queue.clear()
	queue_head = 0
	inflight.clear()
	buffered.clear()
	next_sequence = 0
	next_receive = 1

func backlog() -> int:
	return queue.size() - queue_head + inflight.size()

func _process(_delta: float) -> void:
	if peer == 0 or not Netcode.is_in_room():
		return
	for i in range(inflight.size() - 1, -1, -1):
		var packet := inflight[i]
		var result: NetcodeRpcResult = packet.result
		if not result.is_finished():
			continue
		inflight.remove_at(i)
		if not result.get_error().is_empty():
			rejected += 1
			packet.erase("result")
			if queue_head > 0:
				queue_head -= 1
				queue[queue_head] = packet
			else:
				queue.push_front(packet)
	var pumped := mini(queue.size() - queue_head, IN_FLIGHT - inflight.size())
	for _index in pumped:
		var packet := queue[queue_head]
		var result: NetcodeRpcResult = Netcode.rpc_to_player(peer, event, packet.sequence, packet.code, packet.bytes)
		if result == null or (result.is_finished() and not result.get_error().is_empty()):
			rejected += 1
			break
		sent += 1
		queue[queue_head] = {}
		queue_head += 1
		packet.result = result
		inflight.append(packet)
	if queue_head >= 128 and queue_head * 2 >= queue.size():
		queue = queue.slice(queue_head)
		queue_head = 0

func send_movement(master: int, run_id: int, sequence: int, axis: Vector2) -> void:
	Netcode.rpc_to_player(master, input_sample, run_id, sequence, axis)
	sent += 1

@rpc("any_peer", "call_remote", "reliable")
func event(sequence: int, code: int, bytes: PackedByteArray) -> void:
	if bytes.is_empty() or bytes.size() > MAX_FIELDS * 4 or bytes.size() % 4 != 0:
		return
	var sender := Netcode.get_rpc_sender()
	if sender != peer or sequence < next_receive or sequence >= next_receive + RECEIVE_WINDOW:
		return
	var started := Time.get_ticks_usec()
	received += 1
	buffered[sequence] = {"code": code, "fields": bytes.to_int32_array()}
	while buffered.has(next_receive):
		var packet := buffered[next_receive]
		buffered.erase(next_receive)
		next_receive += 1
		message.emit(sender, packet.code, packet.fields)
	message_us += Time.get_ticks_usec() - started

@rpc("any_peer", "call_remote", "unreliable")
func input_sample(run_id: int, sequence: int, axis: Vector2) -> void:
	received += 1
	movement.emit(Netcode.get_rpc_sender(), run_id, sequence, axis)

static func pack_point(point: Vector2) -> PackedInt32Array:
	return PackedInt32Array([roundi(point.x * 1000.0), roundi(point.y * 1000.0)])

static func point(fields: PackedInt32Array, index: int) -> Vector2:
	return Vector2(fields[index], fields[index + 1]) * 0.001
