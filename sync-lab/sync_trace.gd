extends RefCounted

const Orb = preload("res://orb.gd")
const SAMPLE_IDS := [0, 1, 2, 24, 25, 126, 127, 510, 511]
const GROUP_NAMES := ["player", "global", "aoi1", "aoi2"]

var _last_versions := PackedInt64Array()
var _last_instances := PackedInt64Array()
var _watched := {}
var _resets := {}
var _writes := 0
var _player_writes := 0
var _skipped_writes := 0
var _next_sample := 0
var _last_sample := 0

func _init(count: int) -> void:
	_last_versions.resize(count)
	_last_instances.resize(count)

func written(index: int, accepted: bool) -> void:
	if not accepted:
		_skipped_writes += 1
	elif index < 2:
		_player_writes += 1
	else:
		_writes += 1

func sample(backend: Node, orbs: Array[Orb], host: bool, session: Dictionary) -> void:
	var ticks := Time.get_ticks_msec()
	if ticks < _next_sample:
		return
	_next_sample = ticks + 1000
	var unix_ms := roundi(Time.get_unix_time_from_system() * 1000)
	var groups := {}
	for group in GROUP_NAMES:
		groups[group] = {"visible": 0, "with_sample": 0, "advanced": 0, "new_instances": 0, "oldest_ms": null}
	var samples := {}
	var paths := {}
	for i in orbs.size():
		if not backend.visible(i):
			continue
		var orb := orbs[i]
		if i in SAMPLE_IDS:
			samples[str(i)] = {"wave": orb.version >> 34, "sent_unix_ms": orb.sent_at}
			paths[str(orb.get_path())] = i
			_watch_reset(orb)
		if (host and i != 1) or (not host and i == 1):
			continue
		var group := 0 if i < 2 else (1 if i < Orb.GLOBAL_COUNT else 2 + i % 2)
		var counts: Dictionary = groups[GROUP_NAMES[group]]
		counts.visible += 1
		if orb.sent_at > 0:
			counts.with_sample += 1
			var age := maxi(0, unix_ms - orb.sent_at)
			counts.oldest_ms = age if counts.oldest_ms == null else maxi(age, counts.oldest_ms)
		var id := orb.get_instance_id()
		if id != _last_instances[i]:
			counts.new_instances += 1
			_last_instances[i] = id
		elif orb.sent_at > 0 and orb.version > _last_versions[i]:
			counts.advanced += 1
		_last_versions[i] = orb.version
	session.merge({"role": "A" if host else "B", "unix_ms": unix_ms,
		"interval_ms": ticks - _last_sample if _last_sample else 0, "player_writes": _player_writes,
		"load_writes": _writes, "skipped_writes": _skipped_writes, "remote_groups": groups,
		"sample_objects": samples, "sdk_state_resets": _resets})
	print("SYNC_LAB_TRACE ", JSON.stringify(session))
	if EngineDebugger.is_active():
		EngineDebugger.send_message("sync_lab:watched_objects", [paths])
	_last_sample = ticks
	_player_writes = 0
	_writes = 0
	_skipped_writes = 0
	_resets.clear()

func _watch_reset(orb: Orb) -> void:
	var sync := orb.get_node_or_null("Sync")
	if sync == null or not sync.has_signal("state_reset"):
		return
	var id := orb.get_instance_id()
	if _watched.get(orb.index) == id:
		return
	_watched[orb.index] = id
	sync.state_reset.connect(_on_state_reset.bind(orb.index))

func _on_state_reset(info, index: int) -> void:
	var key := "%d:%d" % [index, info.get_reason()]
	_resets[key] = int(_resets.get(key, 0)) + 1
