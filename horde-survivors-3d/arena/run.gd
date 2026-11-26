
extends Node3D

const Rules = preload("res://combat/rules.gd")
const State = preload("res://actors/state.gd")
const Battle = preload("res://combat/battle.gd")
const Wire = preload("res://net/channel.gd")
const Code = Wire.Code
const Probe = preload("res://benchmark/probe.gd")
const EnemyType = preload("res://actors/enemy_type.gd")
const DEFAULT_SEED := 78301
const STRESS_BATCH_SIZE := 24
const STRESS_BATCH_INTERVAL := 6

@onready var channel: Wire = $Channel
@onready var spawner: NetcodeSpawner = $Objects/Spawner
@onready var arena = $Arena
@onready var map = $Map
@onready var enemy_types: Array[EnemyType] = [
	$EnemyTypes/Grunt, $EnemyTypes/Charger, $EnemyTypes/Boss, $EnemyTypes/Practice,
]
var battle: Battle
var probe: Probe
var host := false
var host_id := 0
var local_id := 0
var guest_id := 0
var members: Dictionary[int, bool] = {}
var motions: Dictionary[int, State] = {}
var vitals: Dictionary[int, State] = {}
var enemies: Dictionary[int, State] = {}
var builds: Dictionary[int, Dictionary] = {}
var pending_rounds: Dictionary[int, int] = {}
var confirmed_writers: Dictionary[int, bool] = {}
var recovering: Dictionary[int, State] = {}
var rng := RandomNumberGenerator.new()
var mode := 1
var gameplay: int = Rules.Gameplay.SURVIVAL
var run_id := 0
var seed := DEFAULT_SEED
var start_at := 0
var step := 0
var result := Rules.Result.LIVE
var boss_id := 0
var next_enemy := 100
var next_wave := 0
var last_spawn_group := 0
var guest_ready := false
var lobby_status := "Host a room or join a teammate."
var room_open := false
var sent_ready := false
var departing := false
var next_claim := 0
var claim_number := 0
var claim_waits: Dictionary[int, int] = {}
var claimed: Dictionary[int, int] = {}
var next_choice := 0
var choice_request := -1
var remote_axis := Vector2.ZERO
var remote_sequence := 0
var remote_input_until := 0
var local_sequence := 0
var last_input := Vector2.ZERO
var ai_us := 0
var combat_us := 0
var write_waits: Array[float] = []
var handoffs := 0

func _ready() -> void:
	battle = Battle.new(self)
	probe = Probe.new(self)
	Netcode.room_joined.connect(joined)
	Netcode.room_left.connect(left_room)
	Netcode.connection_failed.connect(connection_failed)
	Netcode.player_left.connect(player_left)
	arena.setup(self, probe.simple)
	probe.boot()

func open_room(as_host: bool, address: String, port: int, selected_mode: int, selected_gameplay := Rules.Gameplay.SURVIVAL) -> void:
	if room_open or port < 1024 or port > 65535 or address.is_empty():
		return
	host = as_host
	mode = selected_mode
	gameplay = selected_gameplay if host else Rules.Gameplay.SURVIVAL
	run_id = int(randi() % 2000000000) + 1 if host else 0
	seed = probe.seed
	rng.seed = seed
	lobby_status = "Opening TCP room…" if host else "Connecting to room…"
	room_open = true
	var status: Error
	if host:
		var options := NetcodeRoomOptions.new()
		options.max_players = 2
		options.allow_guest_spawns = false
		options.custom_properties = {"run": run_id, "mode": mode, "seed": seed, "gameplay": gameplay}
		status = Netcode.create_room(address, port, options)
	else:
		status = Netcode.join_room(address, port)
	if status != OK:
		connection_failed(error_string(status))

func joined() -> void:
	var room: NetcodeRoomView = Netcode.get_room()
	var properties := room.get_custom_properties()
	local_id = Netcode.get_local_player_id()
	host_id = room.get_master_client_id()
	if not host:
		run_id = int(properties.get("run", 0))
		mode = int(properties.get("mode", 1))
		gameplay = int(properties.get("gameplay", Rules.Gameplay.SURVIVAL))
		seed = int(properties.get("seed", DEFAULT_SEED))
		if run_id <= 0:
			close_room()
			return
		channel.set_peer(host_id)
	lobby_status = "Room ready. Waiting for teammate…" if host else "Synchronizing players…"
	probe.event("joined", {"role": "host" if host else "guest", "player": local_id, "mode": mode,
		"godot": Engine.get_version_info().string, "sdk": FileAccess.get_file_as_string("res://addons/netcode/build-id.txt").strip_edges()})

func close_room() -> void:
	departing = true
	if room_open:
		Netcode.leave_room()
	call_deferred("reload_lobby")

func reload_lobby() -> void:
	get_tree().reload_current_scene()

func left_room() -> void:
	room_open = false
	if departing or probe.active:
		return
	if start_at > 0 or local_id != 0:
		lobby_status = "Room closed. Returning to lobby."
		call_deferred("reload_lobby")

func connection_failed(reason: String) -> void:
	room_open = false
	lobby_status = reason
	probe.event("connection_failed", {"reason": reason})

func player_left(player: int, _inactive: bool) -> void:
	members.erase(player)
	if channel.peer == player:
		channel.set_peer(0)
	if not host:
		return
	probe.event("player_left", {"player": player})
	if probe.test == "capacity" and probe.summary_after_ms > 0:
		return
	if start_at == 0:
		for table: Dictionary in [motions, vitals]:
			if table.has(player):
				spawner.despawn(table[player])
		guest_id = 0
		guest_ready = false
		return
	for enemy: State in enemies.values():
		if enemy.controller == player:
			recover(enemy)
	for id: int in battle.book.deaths:
		var record := battle.book.enemies[id]
		if int(record.owner) == player:
			record.owner = host_id
			record.generation += 1
			handoffs += 1
	if battle.pending.size() > 0:
		battle.retry(step)

func register_state(node: Node) -> void:
	var actor := node as State
	if actor == null:
		return
	actor.sync.authority_requested.connect(actor.permit)
	match actor.kind:
		State.Kind.MOTION:
			motions[actor.entity_id] = actor
			members[actor.entity_id] = true
			ensure_build(actor.entity_id)
		State.Kind.VITALS:
			vitals[actor.entity_id] = actor
		State.Kind.ENEMY:
			actor.enemy_type = enemy_types[actor.species]
			enemies[actor.entity_id] = actor
			actor.lane = Vector2.from_angle(actor.entity_id * 2.399963)
			battle.book.add_enemy(actor.entity_id, actor.hp, actor.controller)
			battle.replay_early_receipts(actor.entity_id)
			actor.waiting = actor.controller != host_id
			if actor.species == State.Species.BOSS:
				boss_id = actor.entity_id
	if actor.controller == local_id and not host:
		actor.request_started = Time.get_ticks_usec()

func unregister_state(node: Node) -> void:
	var actor := node as State
	if actor == null:
		return
	match actor.kind:
		State.Kind.MOTION:
			motions.erase(actor.entity_id)
		State.Kind.VITALS:
			vitals.erase(actor.entity_id)
		State.Kind.ENEMY:
			enemies.erase(actor.entity_id)
			confirmed_writers.erase(actor.entity_id)

func spawn_player(player: int, team: int) -> void:
	var origin: Vector2 = map.spawn_origin(team)
	spawner.spawn(spawner.spawnable_scenes[State.Kind.MOTION], func(_sync, actor: State) -> void:
		actor.entity_id = player
		actor.controller = host_id if mode == 0 else player
		actor.position_xz = origin
		actor.team = team)
	spawner.spawn(spawner.spawnable_scenes[State.Kind.VITALS], func(_sync, actor: State) -> void:
		actor.entity_id = player
		actor.controller = player
		actor.team = team)

func spawn_enemy(species: int, position: Vector2, controller: int, hp := -1) -> State:
	var id := next_enemy
	var health := enemy_types[species].initial_hp if hp < 0 else hp
	var node := spawner.spawn(spawner.spawnable_scenes[State.Kind.ENEMY], func(_sync, actor: State) -> void:
		actor.entity_id = id
		actor.controller = controller
		actor.position_xz = position
		actor.hp = health
		actor.species = species
		actor.target = controller
		actor.source_step = step)
	if node != null:
		next_enemy += 1
	return node as State

func _physics_process(delta: float) -> void:
	if local_id == 0 or not Netcode.is_simulation_ready():
		return
	if start_at == 0:
		update_lobby()
		return
	step = maxi(step, network_step() - start_at)
	if step < 0 or network_step() < start_at:
		return
	if result != Rules.Result.LIVE:
		battle.flush_receipts()
		probe.settled()
		return
	probe.before_step()
	restore_recovered()
	request_writers()
	update_motion(delta)
	var ai_start := Time.get_ticks_usec()
	update_enemies(delta)
	ai_us += Time.get_ticks_usec() - ai_start
	var combat_start := Time.get_ticks_usec()
	battle.update(step)
	battle.flush_receipts()
	update_claims()
	combat_us += Time.get_ticks_usec() - combat_start
	if host and not probe.controls_waves():
		update_run()
	probe.after_step()

func _process(delta: float) -> void:
	arena.present(delta)
	probe.frame(delta)

func update_lobby() -> void:
	var room: NetcodeRoomView = Netcode.get_room()
	if room == null:
		return
	if host:
		var players := room.get_players()
		if players.size() == 2 and guest_id == 0:
			for player: NetcodePlayer in players:
				if player.number != host_id:
					guest_id = player.number
			channel.set_peer(guest_id)
			if not motions.has(host_id):
				spawn_player(host_id, 0)
			spawn_player(guest_id, 1)
			lobby_status = "Synchronizing players…"
		if guest_id != 0 and guest_ready:
			start_at = network_step() + 42
			channel.send(0, Code.START, PackedInt32Array([run_id, start_at]))
			start_round()
	else:
		request_writers()
		var motion: State = motions.get(local_id)
		var life: State = vitals.get(local_id)
		if not sent_ready and life != null and life.sync.is_write_ready() and motion != null and (mode == 0 or motion.sync.is_write_ready()):
			sent_ready = true
			guest_id = local_id
			channel.send(host_id, Code.READY, PackedInt32Array([run_id]))

func start_round() -> void:
	step = 0
	probe.event("started", {"start_at": start_at, "mode": mode})
	arena.enter_match()

func network_step() -> int:
	return floori(Netcode.get_network_time() * Rules.HZ)

func request_writers() -> void:
	if host:
		return
	var now := Time.get_ticks_usec()
	var writable := PackedInt32Array([run_id])
	for table: Dictionary in [motions, vitals, enemies]:
		for actor: State in table.values():
			if actor.controller != local_id or actor.request_started <= 0:
				continue
			if actor.sync.is_write_ready():
				write_waits.append(float(now - actor.request_started) / 1000.0)
				actor.request_started = 0
				actor.waiting = false
				if actor.kind == State.Kind.ENEMY:
					writable.append(actor.entity_id)
					if writable.size() == Wire.MAX_FIELDS:
						channel.send(host_id, Code.WRITABLE, writable)
						writable.resize(1)
			elif now >= actor.next_request and actor.sync.get_object_id() > 0:
				actor.sync.want_authority(true)
				actor.next_request = now + 750000
	if writable.size() > 1:
		channel.send(host_id, Code.WRITABLE, writable)

func recover(enemy: State) -> void:
	enemy.sync.reclaim_authority()
	var record := battle.book.enemies[enemy.entity_id]
	record.generation += 1
	record.owner = host_id
	recovering[enemy.entity_id] = enemy
	confirmed_writers.erase(enemy.entity_id)
	handoffs += 1

func restore_recovered() -> void:
	for id: int in recovering.keys():
		var enemy := recovering[id]
		if not is_instance_valid(enemy) or enemy.is_queued_for_deletion():
			recovering.erase(id)
			continue
		if not enemy.sync.is_write_ready():
			enemy.sync.reclaim_authority()
			continue
		var record := battle.book.enemies[id]
		enemy.controller = host_id
		enemy.generation = int(record.generation)
		enemy.hp = int(record.hp)
		enemy.version = int(record.version)
		enemy.waiting = false
		recovering.erase(id)

func actual_owner(id: int) -> int:
	var enemy: State = enemies.get(id)
	if enemy == null:
		return int(battle.book.enemies.get(id, {}).get("owner", host_id))
	if enemy.controller == host_id or not members.has(enemy.controller):
		return host_id
	if not host or confirmed_writers.has(id):
		return enemy.controller
	return host_id if enemy.sync.is_write_ready() else enemy.controller

func generation(id: int) -> int:
	if id == 0:
		return 1
	return int(battle.book.enemies.get(id, {}).get("generation", 0))

func update_motion(delta: float) -> void:
	var axis := probe.movement()
	if not probe.active:
		axis = Vector2(float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
			float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	axis = axis.limit_length()
	var life: State = vitals.get(local_id)
	if life == null or life.hp <= 0:
		axis = Vector2.ZERO
	var mine: State = motions.get(local_id)
	if mine != null and axis != last_input:
		probe.input_sample(axis, mine.position_xz)
		last_input = axis
	if mode == 0 and not host and (step % 3 == 0 or axis != remote_axis):
		local_sequence += 1
		remote_axis = axis
		channel.send_movement(host_id, run_id, local_sequence, axis)
	for player: int in motions:
		var motion := motions[player]
		if not motion.sync.is_write_ready():
			continue
		var input := axis if player == local_id else remote_axis
		if not members.has(player) or (player != local_id and (step >= remote_input_until or vitals[player].hp <= 0)):
			input = Vector2.ZERO
		var origin := motion.position_xz
		motion.position_xz = map.move(origin, input * Rules.MOVE_SPEED * delta)
		motion.velocity = (motion.position_xz - origin) / delta
		if input != Vector2.ZERO:
			motion.facing = input
		if motion.velocity != Vector2.ZERO or step - motion.source_step >= 15:
			motion.source_step = step

func receive_axis(sender: int, id: int, sequence: int, axis: Vector2) -> void:
	if host and mode == 0 and id == run_id and sender == guest_id and sequence > remote_sequence and axis.is_finite():
		remote_axis = axis.limit_length()
		remote_sequence = sequence
		remote_input_until = step + 30

func update_enemies(delta: float) -> void:
	for enemy: State in enemies.values():
		if enemy.hp <= 0 or (host and (enemy.waiting or recovering.has(enemy.entity_id))):
			continue
		enemy.local_motion_writer = enemy.sync.is_write_ready()
		if not enemy.local_motion_writer:
			continue
		enemy.is_visual_proxy = false
		if probe.frozen(enemy):
			continue
		if step % 15 == enemy.entity_id % 15 or not vitals.has(enemy.target):
			retarget(enemy)
		var target: State = motions.get(enemy.target)
		if target == null:
			continue
		var offset := target.position_xz - enemy.position_xz
		var speed := enemy.enemy_type.speed
		var direction := offset.normalized()
		if enemy.species == State.Species.GRUNT:
			var spread := minf(2.9, offset.length() * 0.48)
			direction = (offset + enemy.lane * spread).normalized()
			speed *= 0.80 + 0.39 * float(enemy.entity_id % 17) / 16.0
		if enemy.species == State.Species.CHARGER:
			if offset.length_squared() < 100.0 and step >= enemy.cooldown_until:
				enemy.windup_until = step + 39
				enemy.cooldown_until = step + 180
				enemy.charge_direction = direction
				battle.start_danger(enemy.entity_id, enemy.position_xz, enemy.position_xz + direction * 8.0, 0.82, 39, 24, 20)
			if step < enemy.windup_until:
				speed = 0.0
			elif step < enemy.windup_until + 26:
				direction = enemy.charge_direction
				speed = 15.5
		elif enemy.species == State.Species.BOSS and step >= enemy.cooldown_until:
			enemy.cooldown_until = step + 150
			for player: int in motions:
				if members.has(player) and vitals[player].hp > 0:
					battle.start_danger(enemy.entity_id, motions[player].position_xz, motions[player].position_xz, 3.3, 52, 22, 24)
		var combined := Battle.enemy_radius(enemy) + Rules.PLAYER_RADIUS - 0.02
		if direction != Vector2.ZERO and (offset.length_squared() > combined * combined or speed > 10.0):
			var travel := direction * speed * delta
			var destination: Vector2 = map.move(enemy.position_xz, travel, minf(0.48, Battle.enemy_radius(enemy)))
			if destination.distance_squared_to(enemy.position_xz) < travel.length_squared() * 0.045:
				var side := direction.orthogonal() * (1.0 if enemy.entity_id % 2 == 0 else -1.0)
				destination = map.move(enemy.position_xz, side * speed * delta, 0.43)
			enemy.position_xz = destination
			enemy.facing = direction
		enemy.source_step = step

func retarget(enemy: State) -> void:
	var nearest := INF
	enemy.target = 0
	for player: int in motions:
		if not members.has(player) or not vitals.has(player) or vitals[player].hp <= 0:
			continue
		var distance := enemy.position_xz.distance_squared_to(motions[player].position_xz)
		if player == enemy.controller:
			distance *= 0.86
		if distance < nearest:
			nearest = distance
			enemy.target = player

func spawn_wave(count: int, scale := 1.0, chargers := false, health := -1) -> void:
	var group := last_spawn_group
	last_spawn_group += 1
	var first_left := (group + seed) % 2 == 0
	for index in count:
		var side := -1.0 if (index % 2 == 0) == first_left else 1.0
		var owner := host_id
		var use_charger := chargers and index % 7 == 0
		if mode == 2 and not use_charger and members.has(guest_id) and side > 0:
			owner = guest_id
		var point: Vector2 = map.enemy_origin(rng, side, scale)
		spawn_enemy(State.Species.CHARGER if use_charger else State.Species.GRUNT, point, owner, health)

func update_run() -> void:
	if battle.book.level > 0:
		update_upgrades()
	if is_stress_test():
		if step >= next_wave:
			var deficit := Rules.STRESS_ENEMY_LIMIT - battle.book.alive_count
			if deficit > 0:
				spawn_wave(mini(deficit, STRESS_BATCH_SIZE))
			next_wave = step + STRESS_BATCH_INTERVAL
		return
	if boss_id > 0 and int(battle.book.enemies[boss_id].hp) <= 0:
		finish(Rules.Result.VICTORY)
		return
	if all_down():
		finish(Rules.Result.DOWN)
		return
	if step >= Rules.DEADLINE:
		finish(Rules.Result.TIMEOUT)
		return
	if step >= 300 * Rules.HZ and boss_id == 0:
		spawn_enemy(State.Species.BOSS, map.boss_origin(), host_id)
	if step >= next_wave:
		var middle := step >= 120 * Rules.HZ
		var count := 18 if middle else 12
		if step == 0:
			count = 24
		count = mini(count, maxi(0, Rules.SURVIVAL_ENEMY_LIMIT - battle.book.alive_count))
		spawn_wave(count, 1.0, middle)
		next_wave = step + (210 if middle else 315)

func all_down() -> bool:
	for player: int in members:
		if vitals.has(player) and vitals[player].hp > 0:
			return false
	return not members.is_empty()

func enemy_killed(enemy: State) -> void:
	arena.fall(enemy.observed_position(), step)
	spawner.call_deferred("despawn", enemy)

func stone_value(enemy: State) -> int:
	return enemy.enemy_type.stone_value

func auto_attack() -> bool:
	return not probe.controls_waves() or probe.auto_attack()

func ignore_contact() -> bool:
	return probe.controls_waves()

func is_stress_test() -> bool:
	return gameplay == Rules.Gameplay.STRESS_TEST

func update_claims() -> void:
	var mine: State = motions.get(local_id)
	if step < next_claim or mine == null or not vitals.has(local_id) or vitals[local_id].hp <= 0:
		return
	next_claim = step + 5
	if probe.active and not probe.auto_claim():
		return
	for id: int in battle.book.stones:
		var stone: Dictionary = battle.book.stones[id]
		if int(stone.winner) == 0 and step >= int(claim_waits.get(id, 0)) and mine.position_xz.distance_squared_to(stone.position) <= 1.95 * 1.95:
			claim(id)

func claim(id: int) -> void:
	claim_number += 1
	claim_waits[id] = step + 27
	arena.suction(id, local_id, step)
	channel.send(host_id, Code.CLAIM, PackedInt32Array([run_id, id, claim_number]))

func accept_claim(player: int, id: int) -> void:
	if not members.has(player) or not motions.has(player) or not vitals.has(player) or vitals[player].hp <= 0:
		return
	var stone: Dictionary = battle.book.stones.get(id, {})
	if stone.is_empty():
		return
	var origin: Vector2 = motions[player].position_xz
	if int(stone.winner) == 0 and origin.distance_squared_to(stone.position) > 3.0 * 3.0:
		return
	var winner := battle.book.take_stone(id, player)
	var fields := PackedInt32Array([run_id, id, winner, battle.book.xp_version, battle.book.experience, battle.book.level, battle.book.unspent_experience])
	receive_pickup(fields)
	channel.send(0, Code.PICKUP, fields)
	update_upgrades()

func receive_pickup(fields: PackedInt32Array) -> void:
	if battle.book.stones.has(fields[1]):
		battle.book.stones[fields[1]].winner = fields[2]
	claimed[fields[1]] = fields[2]
	claim_waits.erase(fields[1])
	if not host and fields[3] >= battle.book.xp_version:
		battle.book.xp_version = fields[3]
		battle.book.experience = fields[4]
		battle.book.level = fields[5]
		battle.book.unspent_experience = fields[6]
	probe.event("pickup", {"stone": fields[1], "winner": fields[2], "xp": fields[4]})

func ensure_build(player: int) -> void:
	if not builds.has(player):
		builds[player] = {0: PackedInt32Array([0, 0, 0, 0, 0])}

func build_for(player: int) -> PackedInt32Array:
	ensure_build(player)
	var versions := builds[player]
	return versions[versions.size() - 1]

func build_version(player: int, version: int, used_step: int) -> PackedInt32Array:
	var build: PackedInt32Array = builds.get(player, {}).get(version, PackedInt32Array())
	if build.is_empty() or used_step < build[4]:
		return PackedInt32Array()
	return build

func update_upgrades() -> void:
	for player: int in members:
		if vitals[player].hp > 0 and int(pending_rounds.get(player, 0)) == 0 and build_for(player)[0] < battle.book.level:
			pending_rounds[player] = build_for(player)[0] + 1
	if pending_rounds.get(local_id, 0) > 0 and next_choice == 0:
		next_choice = pending_rounds[local_id]

func pick_upgrade(option: int) -> void:
	if next_choice <= 0 or choice_request != -1:
		return
	choice_request = option
	channel.send(host_id, Code.CHOOSE, PackedInt32Array([run_id, next_choice, option]))

func accept_upgrade(player: int, round_no: int, option: int) -> void:
	var key := Vector2i(player, round_no)
	if battle.book.choices.has(key):
		var previous: PackedInt32Array = builds[player][round_no]
		if player != local_id:
			channel.send(player, Code.UPGRADE, upgrade_fields(player, int(battle.book.choices[key]), previous))
		return
	if not members.has(player) or not vitals.has(player) or vitals[player].hp <= 0 or round_no <= 0 or option not in [0, 1, 2] or round_no != int(pending_rounds.get(player, 0)):
		return
	pending_rounds[player] = 0
	var build := build_for(player).duplicate()
	build[0] = round_no
	build[option + 1] += 1
	build[4] = step
	var fields := upgrade_fields(player, option, build)
	receive_upgrade(fields)
	channel.send(0, Code.UPGRADE, fields)
	update_upgrades()

func upgrade_fields(player: int, option: int, build: PackedInt32Array) -> PackedInt32Array:
	var fields := PackedInt32Array([run_id, player, option])
	fields.append_array(build)
	return fields

func receive_upgrade(fields: PackedInt32Array) -> void:
	var player := fields[1]
	var build := fields.slice(3)
	ensure_build(player)
	if builds[player].has(build[0]):
		return
	builds[player][build[0]] = build
	battle.book.choices[Vector2i(player, build[0])] = fields[2]
	if player == local_id:
		choice_request = -1
		next_choice = build[0] + 1 if build[0] < battle.book.level else 0
	probe.event("upgrade", {"player": player, "choice": fields[2], "build": Array(build)})

func finish(outcome: int) -> void:
	if result != Rules.Result.LIVE:
		return
	battle.flush_receipts()
	result = outcome
	channel.send(0, Code.END, PackedInt32Array([run_id, outcome, step]))
	probe.event("finished", {"result": outcome, "step": step})

func receive(sender: int, code: int, fields: PackedInt32Array) -> void:
	if fields.is_empty() or fields[0] != run_id:
		return
	match code:
		Code.READY:
			if host and guest_id == sender and fields.size() == 1:
				guest_ready = true
		Code.START:
			if not host and sender == host_id and fields.size() == 2 and start_at == 0:
				start_at = fields[1]
				start_round()
		Code.WRITABLE:
			if host and sender == guest_id:
				for i in range(1, fields.size()):
					var enemy: State = enemies.get(fields[i])
					if enemy != null and enemy.controller == sender and not enemy.sync.has_authority():
						confirmed_writers[fields[i]] = true
						enemy.waiting = false
		Code.CLAIM:
			if host and fields.size() == 3 and result == Rules.Result.LIVE:
				accept_claim(sender, fields[1])
		Code.PICKUP:
			if sender == host_id and fields.size() == 7:
				receive_pickup(fields)
				if not host and build_for(local_id)[0] < battle.book.level and next_choice == 0 and vitals.has(local_id) and vitals[local_id].hp > 0:
					next_choice = build_for(local_id)[0] + 1
		Code.CHOOSE:
			if host and fields.size() == 3 and result == Rules.Result.LIVE:
				accept_upgrade(sender, fields[1], fields[2])
		Code.UPGRADE:
			if sender == host_id and fields.size() == 8:
				receive_upgrade(fields)
		Code.END:
			if not host and sender == host_id and fields.size() == 3 and result == Rules.Result.LIVE:
				result = fields[1]
				probe.event("finished", {"result": result, "step": fields[2]})
		Code.BENCH_DRAINED, Code.BENCH_DONE:
			if fields.size() == 1:
				probe.drain_message(sender, code)
		Code.BENCH_CLOCK_REQUEST, Code.BENCH_CLOCK_REPLY:
			probe.clock_message(sender, code, fields)
		_:
			if start_at > 0 and (result == Rules.Result.LIVE or code == Code.RECEIPT):
				battle.receive(sender, code, fields)
