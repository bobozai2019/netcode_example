
extends Node

signal message(sender: int, code: int, fields: PackedInt32Array)
signal failed(reason: String)
signal movement(sender: int, run_id: int, sequence: int, axis: Vector2, source_step: int)

enum Code {
	READY, START, ATTACK, HIT, OWNER_HIT, COMMIT, RECEIPT, DANGER, CLAIM, PICKUP,
	CHOOSE, UPGRADE, END, WRITABLE, BENCH_DRAINED, BENCH_DONE, CHAIN,
	BENCH_CLOCK_REQUEST, BENCH_CLOCK_REPLY, CLAIM_REJECT, UPGRADE_REJECT,
}
const MAX_FIELDS := 48
const IN_FLIGHT := 48
const PRIORITY_IN_FLIGHT_RESERVE := 8
const RECEIVE_WINDOW := 4096
const COMBAT_QUEUE_LIMIT := 128
const COMBAT_QUEUE_AGE_MS := 750
const REQUIRED_QUEUE_LIMIT := 2176
const MOVEMENT_IN_FLIGHT := 4
const QUEUE_TIMEOUT_MS := 12000
const SEND_RETRY_MS := 50
const MOVEMENT_TIMEOUT_MS := 250
var sent := 0
var received := 0
var rejected := 0
var message_us := 0
var queue: Array[Dictionary] = []
var queue_head := 0
var priority_end := 0
var inflight: Array[Dictionary] = []
var next_sequence := 0
var next_receive := 1
var buffered: Dictionary[int, Dictionary] = {}
var queue_peak := 0
var peer := 0
var outbound_claims: Dictionary[int, bool] = {}
var outbound_choices: Dictionary[int, bool] = {}
var outbound_hits: Dictionary[Vector3i, bool] = {}
var next_send_at := 0
var failure := false
var movement_latest: Dictionary = {}
var movement_inflight: Array[NetcodeRpcResult] = []
var movement_coalesced := 0
var oldest_queue_ms := 0
var peak_queue_age_ms := 0

func _enter_tree() -> void:
	Netcode.register_broadcast_receiver(self)

func _exit_tree() -> void:
	Netcode.unregister_broadcast_receiver(self)

func send(recipient: int, code: int, fields: PackedInt32Array) -> bool:
	assert(fields.size() <= MAX_FIELDS)
	if failure:
		return false
	if recipient == Netcode.get_local_player_id():
		message.emit(recipient, code, fields)
		return true
	if peer == 0 or (recipient != 0 and recipient != peer):
		return recipient == 0
	if code in [Code.ATTACK, Code.CHAIN] and not can_start_combat():
		return false
	var keys := PackedInt32Array()
	var hit_keys: Array[Vector3i] = []
	if code == Code.HIT:
		var unique_hits := fields.slice(0, 4)
		for index in range(4, fields.size(), 2):
			var hit := Vector3i(fields[1], fields[index], fields[2])
			if not outbound_hits.has(hit):
				unique_hits.append(fields[index])
				unique_hits.append(fields[index + 1])
				hit_keys.append(hit)
		if hit_keys.is_empty():
			return true
		fields = unique_hits
	elif code == Code.CLAIM:
		for index in range(1, fields.size(), 2):
			keys.append(fields[index])
	elif code == Code.CHOOSE:
		if outbound_choices.has(fields[1]):
			return true
		keys.append(fields[1])
	if backlog() >= REQUIRED_QUEUE_LIMIT:
		fail_stream("Required network actions filled the queue. The room was closed.")
		return false
	for key in keys:
		if code == Code.CLAIM:
			outbound_claims[key] = true
		else:
			outbound_choices[key] = true
	for hit in hit_keys:
		outbound_hits[hit] = true
	var packet := {"sequence": 0, "code": code, "bytes": fields.to_byte_array(),
		"operation_keys": keys, "hit_keys": hit_keys, "queued_at": Time.get_ticks_msec()}
	# These messages are independent of queued combat. They retain their own FIFO.
	if code in [Code.READY, Code.START, Code.CLAIM, Code.PICKUP, Code.CHOOSE, Code.UPGRADE, Code.CLAIM_REJECT, Code.UPGRADE_REJECT]:
		priority_end = maxi(queue_head, priority_end)
		queue.insert(priority_end, packet)
		priority_end += 1
	else:
		queue.append(packet)
	queue_peak = maxi(queue_peak, backlog())
	return true

func can_start_combat() -> bool:
	return not failure and backlog() < COMBAT_QUEUE_LIMIT and oldest_queue_ms < COMBAT_QUEUE_AGE_MS

func is_claim_queued(id: int) -> bool:
	return outbound_claims.has(id)

func is_hit_queued(attack: int, target: int, segment: int) -> bool:
	return outbound_hits.has(Vector3i(attack, target, segment))

func fail_stream(reason: String) -> void:
	if not failure:
		failure = true
		call_deferred("emit_signal", "failed", reason)

func set_peer(player: int) -> void:
	if peer == player:
		return
	peer = player
	queue.clear()
	queue_head = 0
	priority_end = 0
	inflight.clear()
	buffered.clear()
	next_sequence = 0
	next_receive = 1
	next_send_at = 0
	failure = false
	oldest_queue_ms = 0
	outbound_claims.clear()
	outbound_choices.clear()
	outbound_hits.clear()
	movement_latest.clear()
	movement_inflight.clear()

func backlog() -> int:
	return queue.size() - queue_head + inflight.size()

func _process(_delta: float) -> void:
	if failure or peer == 0 or not Netcode.is_in_room():
		return
	var now := Time.get_ticks_msec()
	var oldest := now
	for i in range(inflight.size() - 1, -1, -1):
		var packet := inflight[i]
		var result: NetcodeRpcResult = packet.result
		if not result.is_finished():
			oldest = mini(oldest, packet.queued_at)
			continue
		inflight.remove_at(i)
		if result.get_error().is_empty():
			for key: int in packet.operation_keys:
				if packet.code == Code.CLAIM:
					outbound_claims.erase(key)
				else:
					outbound_choices.erase(key)
			for hit: Vector3i in packet.hit_keys:
				outbound_hits.erase(hit)
			continue
		rejected += 1
		packet.erase("result")
		if queue_head > 0:
			queue_head -= 1
			queue[queue_head] = packet
		else:
			queue.push_front(packet)
			priority_end += 1
		priority_end = maxi(priority_end, queue_head + 1)
		next_send_at = now + SEND_RETRY_MS
	if queue_head < queue.size():
		oldest = mini(oldest, queue[queue_head].queued_at)
	if priority_end > queue_head and priority_end < queue.size():
		oldest = mini(oldest, queue[priority_end].queued_at)
	oldest_queue_ms = now - oldest
	peak_queue_age_ms = maxi(peak_queue_age_ms, oldest_queue_ms)
	if oldest_queue_ms >= QUEUE_TIMEOUT_MS:
		fail_stream("Network actions could not be delivered for 12 seconds. The room was closed.")
		return
	if now >= next_send_at:
		var pumped := mini(queue.size() - queue_head, IN_FLIGHT - inflight.size())
		for _index in pumped:
			var packet := queue[queue_head]
			var sequence := int(packet.sequence)
			if sequence == 0:
				if queue_head >= priority_end and inflight.size() >= IN_FLIGHT - PRIORITY_IN_FLIGHT_RESERVE:
					break
				sequence = next_sequence + 1
			var result: NetcodeRpcResult = Netcode.rpc_to_player(peer, event, sequence, packet.code, packet.bytes)
			if result == null or (result.is_finished() and not result.get_error().is_empty()):
				rejected += 1
				next_send_at = now + SEND_RETRY_MS
				break
			next_sequence = maxi(next_sequence, sequence)
			packet.sequence = sequence
			sent += 1
			queue[queue_head] = {}
			queue_head += 1
			packet.result = result
			inflight.append(packet)
	if queue_head >= 128 and queue_head * 2 >= queue.size():
		queue = queue.slice(queue_head)
		priority_end = maxi(0, priority_end - queue_head)
		queue_head = 0
	flush_movement(now)

func send_movement(master: int, run_id: int, sequence: int, axis: Vector2, source_step: int) -> void:
	if failure or master != peer:
		return
	if not movement_latest.is_empty():
		movement_coalesced += 1
	movement_latest = {"run_id": run_id, "sequence": sequence, "axis": axis, "source_step": source_step,
		"queued_at": Time.get_ticks_msec()}

func flush_movement(now: int) -> void:
	for i in range(movement_inflight.size() - 1, -1, -1):
		if movement_inflight[i].is_finished():
			movement_inflight.remove_at(i)
	if movement_latest.is_empty() or movement_inflight.size() >= MOVEMENT_IN_FLIGHT:
		return
	var sample := movement_latest
	movement_latest = {}
	if now - int(sample.queued_at) >= MOVEMENT_TIMEOUT_MS:
		return
	var result: NetcodeRpcResult
	if int(sample.source_step) >= 0:
		result = Netcode.rpc_to_player(peer, input_sample_at, sample.run_id, sample.sequence, sample.axis, sample.source_step)
	else:
		result = Netcode.rpc_to_player(peer, input_sample, sample.run_id, sample.sequence, sample.axis)
	if result != null and (not result.is_finished() or result.get_error().is_empty()):
		if not result.is_finished():
			movement_inflight.append(result)
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
	movement.emit(Netcode.get_rpc_sender(), run_id, sequence, axis, -1)

@rpc("any_peer", "call_remote", "unreliable")
func input_sample_at(run_id: int, sequence: int, axis: Vector2, source_step: int) -> void:
	received += 1
	movement.emit(Netcode.get_rpc_sender(), run_id, sequence, axis, source_step)

static func pack_point(point: Vector2) -> PackedInt32Array:
	return PackedInt32Array([roundi(point.x * 1000.0), roundi(point.y * 1000.0)])

static func point(fields: PackedInt32Array, index: int) -> Vector2:
	return Vector2(fields[index], fields[index + 1]) * 0.001
