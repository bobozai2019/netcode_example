
extends RefCounted

const State = preload("res://actors/state.gd")
const Rules = preload("res://combat/rules.gd")
const Wire = preload("res://net/channel.gd")
const MotionMetrics = preload("res://benchmark/enemy_motion.gd")
const EnemyReplication = preload("res://actors/enemy_replication.tres")
var game
var active := false
var simple := false
var raw_enemies := false
var native_smoothing := false
var enemy_motion := MotionMetrics.new()
var direct_proxy_count := -1
var seed := 78301
var args: Dictionary[String, String] = {}
var scenario := "split"
var test := ""
var count := 128
var duration := 12.0
var warmup := 5.0
var sampled := false
var completed := false
var frames: Array[float] = []
var ages: Array[float] = []
var age_seen := 0
var age_rng := RandomNumberGenerator.new()
var rtts: Array[float] = []
var ownership: Array[int] = []
var visible: Array[int] = []
var population: Array[int] = []
var queue_bytes: Array[int] = []
var rows: Array[Array] = []
var motion_times: Array[float] = []
var pending_attack_frames: Array[int] = []
var hit_feedback: Array[float] = []
var clock_samples: Array[Array] = []
var next_clock_step := 0
var clock_sent_ms := -1
var movement_started := 0
var started_at_position := Vector2.ZERO
var started_axis := Vector2.ZERO
var measure_from := 0
var last_frame_at := 0
var collect_after := 0
var finish_at := 0
var end_step := 0
var mark := {}
var errors: Array[String] = []
var marks := {}
var staged := 0
var spawned := 0
var boot_time := 0
var next_measure := 0
var once_frame := false
var remote_drained := false
var summary_after_ms := 0
var ownership_error := false
var next_turn := 0
var steering := Vector2.ZERO
var selection_start := Vector2.ZERO

func _init(session) -> void:
	game = session
	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("--"):
			continue
		var pieces := argument.trim_prefix("--").split("=", true, 1)
		args[pieces[0]] = pieces[1] if pieces.size() == 2 else "true"
	active = args.has("case")
	simple = args.has("simple")
	native_smoothing = args.has("netcode-smoothing")
	raw_enemies = args.has("raw-enemies") or native_smoothing
	test = args.get("case", "")
	scenario = args.get("scenario", "split")
	seed = int(args.get("seed", "78301"))
	age_rng.seed = seed
	count = clampi(int(args.get("size", "128")), 1, 1024)
	duration = float(args.get("seconds", "12"))
	warmup = float(args.get("warmup", "5"))

func boot() -> void:
	if native_smoothing:
		var config: NetcodeReplicationConfig = EnemyReplication
		var properties: Array[NodePath] = [NodePath(":position_xz"), NodePath(":facing")]
		config.smooth_properties = properties
	if not active:
		return
	boot_time = Time.get_ticks_msec()
	var role: String = args.get("role", "host")
	var address: String = args.get("address", "127.0.0.1")
	game.open_room(role == "host", address, int(args.get("port", "43391")), ["A", "B", "C"].find(args.get("mode", "B")))

func event(name: String, info: Dictionary) -> void:
	if active:
		var row := info.duplicate()
		row.event = name
		row.step_local = game.step
		print("HORDE_EVENT ", JSON.stringify(row))

func controls_waves() -> bool:
	return active and test != "natural"

func auto_attack() -> bool:
	return test == "capacity" and game.step >= collect_after - Rules.HZ and not sampled

func auto_claim() -> bool:
	return test == "natural" or (test == "capacity" and not sampled)

func frozen(enemy: State) -> bool:
	return (test == "capacity" and sampled) or (controls_waves() and enemy.species == State.Species.PRACTICE)

func movement() -> Vector2:
	if test == "natural":
		return natural_input()
	if test == "capacity":
		if sampled:
			return Vector2.ZERO
		var team: int = game.motions[game.local_id].team
		var side := -1.0 if team == 0 else 1.0
		var index: int = (game.step / 108) % 4
		if game.step < 92 and scenario == "split":
			return Vector2(side, 0)
		if game.step < 35 and scenario != "split":
			return Vector2(-side, 0)
		if scenario == "burst":
			return [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT][index] * 0.24
		if scenario == "merge":
			return [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT][index] * 0.62
		return [Vector2.UP, Vector2(-side, 0), Vector2.DOWN, Vector2(side, 0)][index]
	if test == "rules":
		if game.step in range(432, 483) and not game.host:
			return Vector2.DOWN
		if game.step in range(650, 701) and game.host:
			return Vector2.LEFT
		if game.step in range(745, 796) and game.host:
			return Vector2.RIGHT
		if game.step in range(780, 831) and not game.host:
			return Vector2.UP
		if game.step >= 833 and game.step < 868:
			return Vector2.RIGHT if game.host else Vector2.LEFT
	if test in ["before", "after"] and game.host and game.step >= 350:
		return Vector2.DOWN
	if test == "win" and not game.host and game.step in range(94, 135):
		return Vector2.DOWN
	return Vector2.ZERO

func input_sample(axis: Vector2, point: Vector2) -> void:
	if active and axis != Vector2.ZERO:
		movement_started = Time.get_ticks_usec()
		started_at_position = point
		started_axis = axis.normalized()

func attack_started(start_us: int) -> void:
	if active:
		pending_attack_frames.append(start_us)

func hit_presented(start_us: int) -> void:
	if test == "capacity" and not sampled and not frames.is_empty() and start_us >= int(mark.clock):
		hit_feedback.append(float(Time.get_ticks_usec() - start_us) / 1000.0)

func observe_enemy_motion(enemy: State, frame_us: int) -> void:
	if test == "capacity" and not sampled and collect_after > 0 and game.step >= collect_after:
		enemy_motion.observe(enemy, frame_us)

func sample_room_clock() -> void:
	if sampled or game.channel.peer <= 0 or game.step < collect_after or game.step < next_clock_step:
		return
	next_clock_step = game.step + 2 * Rules.HZ
	clock_sent_ms = roundi(Netcode.get_network_time() * 1000.0)
	game.channel.send(game.channel.peer, Wire.Code.BENCH_CLOCK_REQUEST,
		PackedInt32Array([game.run_id, clock_sent_ms]))

func clock_message(sender: int, code: int, fields: PackedInt32Array) -> void:
	if test != "capacity" or game.step < collect_after or collect_after == 0 or sender != game.channel.peer:
		return
	var received := roundi(Netcode.get_network_time() * 1000.0)
	if code == Wire.Code.BENCH_CLOCK_REQUEST and fields.size() == 2:
		var sent := roundi(Netcode.get_network_time() * 1000.0)
		game.channel.send(sender, Wire.Code.BENCH_CLOCK_REPLY,
			PackedInt32Array([game.run_id, fields[1], received, sent]))
	elif not sampled and code == Wire.Code.BENCH_CLOCK_REPLY and fields.size() == 4 and fields[1] == clock_sent_ms:
		# Without assuming symmetric paths, causality bounds peer clock minus local clock.
		# A millisecond on either side accounts for converting the clocks to integer ms.
		var lower := fields[3] - received - 1
		var upper := fields[2] - clock_sent_ms + 1
		if lower <= upper:
			clock_samples.append([lower, upper])
		clock_sent_ms = -1

func hurt(at: int, hp: int) -> void:
	event("hurt", {"at": at, "hp": hp})

func before_step() -> void:
	if not active:
		return
	if test == "capacity":
		capacity_step()
		sample_room_clock()
	elif test == "rules":
		rules_step()
	elif test in ["before", "after"]:
		handoff_step()
	elif test in ["win", "down", "timeout"]:
		outcome_step()
	elif test == "natural":
		if once("second_wave", 120 * Rules.HZ):
			event("phase", {"name": "chargers"})
		if game.boss_id != 0 and once("boss_phase", 300 * Rules.HZ):
			event("phase", {"name": "boss"})
		if game.next_choice > 0 and game.choice_request == -1 and game.step % 20 == 0:
			game.pick_upgrade([1, 2, 0][(game.next_choice - 1) % 3])
	if test != "capacity" and game.step >= next_measure:
		next_measure = game.step + 30
		if not game.host:
			rtts.append(Netcode.get_rtt() * 1000.0)

func after_step() -> void:
	if not active:
		return
	if test == "capacity":
		if not sampled and game.step >= end_step and end_step > 0:
			sampled = true
		if finish_at > 0 and game.step >= finish_at:
			var drained: bool = game.battle.pending.is_empty() and game.channel.backlog() == 0
			if not game.host and drained and once("drained", 0):
				game.channel.send(game.host_id, Wire.Code.BENCH_DRAINED, PackedInt32Array([game.run_id]))
			if game.host and drained and remote_drained and once("done", 0):
				game.channel.send(game.guest_id, Wire.Code.BENCH_DONE, PackedInt32Array([game.run_id]))
				summary_after_ms = Time.get_ticks_msec() + 1500
	elif test == "rules" and game.step >= 950:
		if once("rules_checked", 0):
			check_rules()
			if not game.host:
				game.channel.send(game.host_id, Wire.Code.BENCH_DRAINED, PackedInt32Array([game.run_id]))
		if game.host and remote_drained and once("done", 0):
			game.channel.send(game.guest_id, Wire.Code.BENCH_DONE, PackedInt32Array([game.run_id]))
			summary_after_ms = Time.get_ticks_msec() + 1500
	elif test in ["before", "after"] and game.host and game.step >= 525:
		var target: int = 100
		check(game.handoffs == 1, "one delegated enemy recovered")
		check(game.battle.book.hits.size() == 1, "one unique accepted hit")
		check(game.battle.book.deaths.size() == 1 and game.battle.book.stones.size() == 1, "one death and stone")
		check(game.battle.dropped_old_commits == 1, "old generation commit rejected")
		check(game.motions[game.local_id].position_xz.y > 1.0, "host keeps moving")
		check(int(game.battle.book.enemies[target].hp) == 0, "dead target stays dead")
		summary()

func once(name: String, at: int) -> bool:
	if game.step < at or marks.has(name):
		return false
	marks[name] = true
	return true

func natural_input() -> Vector2:
	if game.step < next_turn:
		return steering
	next_turn = game.step + 8
	var mine: State = game.motions[game.local_id]
	var origin := mine.position_xz
	var anchor := Vector2(-13.0 if mine.team == 0 else 13.0, 0)
	var focus := anchor
	var prize := 130.0
	for stone: Dictionary in game.battle.book.stones.values():
		if int(stone.winner) == 0 and origin.distance_squared_to(stone.position) < prize:
			focus = stone.position
			prize = origin.distance_squared_to(focus)
	var boss: State = game.enemies.get(game.boss_id)
	if boss != null:
		focus = boss.position_xz
	var near: Array[Vector2] = []
	for enemy: State in game.enemies.values():
		if enemy.hp > 0 and origin.distance_squared_to(enemy.observed_position()) < 180.0:
			near.append(enemy.observed_position())
	var incoming: Array[Dictionary] = []
	for danger: Dictionary in game.battle.hazards.values():
		if not danger.spent and danger_distance(origin, danger) < float(danger.radius) + 7.0:
			incoming.append(danger)
	var best_score := -INF
	for index in 17:
		var axis := Vector2.from_angle(TAU * index / 16.0) if index < 16 else Vector2.ZERO
		var ahead: Vector2 = game.map.move(game.map.move(origin, axis * 2.1), axis * 2.1)
		var clearance := 7.0
		for threat in near:
			clearance = minf(clearance, ahead.distance_to(threat))
		var cost := ahead.distance_to(focus) if boss == null else absf(ahead.distance_to(focus) - 6.2)
		var score := clearance * 1.55 - cost * (0.35 if boss == null else 0.80) - ahead.length() * 0.022
		for danger in incoming:
			var remaining := maxf(0.0, float(int(danger.active) - game.step) / Rules.HZ)
			var hop := axis * Rules.MOVE_SPEED * remaining / 4.0
			var at_activation := origin
			for _increment in 4:
				at_activation = game.map.move(at_activation, hop)
			var margin := float(danger.radius) + Rules.PLAYER_RADIUS
			var distance := danger_distance(at_activation, danger)
			score -= maxf(0.0, margin + 0.4 - distance) * 26.0
		score += axis.dot(steering) * 0.22
		if score > best_score:
			best_score = score
			steering = axis
	return steering

func danger_distance(point: Vector2, danger: Dictionary) -> float:
	var center: Vector2 = danger.origin
	if danger.origin != danger.end:
		center = Geometry2D.get_closest_point_to_segment(point, danger.origin, danger.end)
	return point.distance_to(center)

func capacity_step() -> void:
	if once("collect", 0):
		collect_after = maxi(120, roundi(warmup * Rules.HZ))
		end_step = collect_after + roundi(duration * Rules.HZ)
		finish_at = end_step + 180
		for player: int in game.motions:
			if scenario == "burst":
				game.builds[player][0] = PackedInt32Array([0, 3, 4, 8, 0])
	if not sampled and game.step >= collect_after and not ownership_error:
		for player: int in game.motions:
			var writer: int = game.host_id if game.mode == 0 else player
			var motion_ready: bool = game.motions[player].sync.is_write_ready()
			var combat_ready: bool = game.vitals[player].sync.is_write_ready()
			if motion_ready != (writer == game.local_id) or combat_ready != (player == game.local_id):
				ownership_error = true
				check(false, "player motion and combat follow selected authority mode")
				break
	if game.host and not sampled and game.step % 3 == 0:
		var deficit: int = count - game.battle.book.alive_count
		var wave := mini(deficit, 24)
		if wave > 0:
			game.spawn_wave(wave, 0.38 if scenario == "burst" else 0.80, false, 180)
			spawned += wave

func rules_step() -> void:
	if game.host and once("setup", 5):
		game.spawn_enemy(State.Species.PRACTICE, Vector2(0, 2.2), game.host_id)
	if once("opening_stone", 5):
		add_stone(90, Vector2(4, 0), 8)
	if once("open_build", 75):
		if not game.host:
			game.claim(90)
	if once("choose_first", 115):
		game.pick_upgrade(0 if game.host else 1)
	if once("first_hit", 175) and game.host:
		fixture_hit(100, Rules.Weapon.KNIFE)
	if once("second_hit", 195) and not game.host:
		fixture_hit(100, Rules.Weapon.HALO)
	if once("duplicate", 225) and game.host:
		resend(100, 1, 0, 1)
	if once("first_hp", 257):
		check(health(100) == 20, "12 + 18 w/ duplicate leaves 20")
		event("cohit", {"hp": health(100)})
	if once("next_pulse", 270) and not game.host:
		resend(100, 1, 1, 1)
	if once("second_hp", 300):
		check(health(100) == 2, "next halo segment leaves 2")
	if once("kill", 312):
		fixture_hit(100, Rules.Weapon.KNIFE)
	if game.host and once("warn_one", 410):
		game.battle.start_danger(0, Vector2(-4, 0), Vector2(-4, 0), 2.2, 64, 20, 13)
		game.battle.start_danger(0, Vector2(4, 0), Vector2(4, 0), 2.2, 64, 20, 13)
		game.battle.start_danger(0, Vector2(-4, 0), Vector2(-4, 0), 2.2, 70, 20, 13)
	if once("check_one", 500):
		var hp: int = game.vitals[game.local_id].hp
		check(hp == (87 if game.host else 100), "host stays, guest dodges, invulnerability")
	if game.host and once("warn_two", 642):
		var host_at: Vector2 = game.motions[game.host_id].position_xz
		var guest_at: Vector2 = game.motions[game.guest_id].position_xz
		game.battle.start_danger(0, host_at, host_at, 2.2, 55, 20, 17)
		game.battle.start_danger(0, guest_at, guest_at, 2.2, 55, 20, 17)
		game.battle.start_danger(0, guest_at, guest_at, 2.2, 63, 20, 17)
	if once("check_two", 750):
		var hp: int = game.vitals[game.local_id].hp
		check(hp == (87 if game.host else 83), "host dodges, guest stays, invulnerability")
	if once("race", 873):
		game.claim(100)
		game.claim(100)
	if once("load_128", 880) and game.host:
		game.spawn_wave(128)

func check_rules() -> void:
	check(game.battle.book.experience == 16 and game.battle.book.xp_version == 2, "shared experience credited once per stone")
	check(game.battle.book.deaths.size() == 1 and game.battle.book.stones.size() == 2, "unique practice death and drop")
	check(game.battle.book.choices.size() == 2, "each player chooses once")
	check(game.battle.book.alive_count == 128, "both ends reach 128 living enemies")
	check(game.vitals[game.host_id].hp == 87 and game.vitals[game.guest_id].hp == 83, "both vitals converge")

func add_stone(id: int, position: Vector2, value: int) -> void:
	game.battle.book.stones[id] = {"position": position, "value": value, "winner": 0}

func fixture_hit(id: int, weapon: int) -> void:
	var enemy: State = game.enemies.get(id)
	if enemy == null:
		return
	var motion: State = game.motions[game.local_id]
	var number: int = game.battle.start_attack(weapon, motion.position_xz, motion.position_xz.direction_to(enemy.position_xz), game.step, false)
	var targets: Array[State] = [enemy]
	game.battle.submit(number, 0, targets)

func resend(id: int, attack: int, segment: int, generation: int) -> void:
	game.channel.send(game.host_id, Wire.Code.HIT, PackedInt32Array([game.run_id, attack, segment, game.step, id, generation]))

func health(id: int) -> int:
	return int(game.battle.book.enemies.get(id, {}).get("hp", -1))

func handoff_step() -> void:
	if game.host and once("spawn", 5):
		game.spawn_enemy(State.Species.PRACTICE, Vector2(1, 0), game.guest_id, 12)
	if not game.host and test == "before":
		game.battle.pause_remote_commits = true
	if game.host and once("hit", 145):
		check(game.confirmed_writers.has(100), "fixture has guest write-ready authority")
		fixture_hit(100, Rules.Weapon.KNIFE)
	if once("leave", 210):
		if not game.host:
			event("disconnect", {"phase": test})
			# Exit abruptly so the host observes TCP peer loss.
			get_tree_quit()
		else:
			check(health(100) == (12 if test == "before" else 0), "disconnect boundary has expected HP")
	if game.host and once("retry", 325):
		if not game.battle.book.hits.has(Vector4i(game.local_id, 1, 100, 0)):
			resend(100, 1, 0, 2)
		game.battle.accept_commit(game.guest_id, PackedInt32Array([game.run_id, game.local_id, 1, 0, 100, 1, 0, 1, 0]))
		resend(100, 1, 0, 1)

func outcome_step() -> void:
	if test == "win":
		win_step()
	elif test == "down" and game.host:
		if once("circles", 60):
			for player: State in game.motions.values():
				game.battle.start_danger(0, player.position_xz, player.position_xz, 3.0, 45, 18, 100)
		if game.all_down():
			game.update_run()
	elif test == "timeout" and game.host:
		if once("boss", 20):
			game.spawn_enemy(State.Species.BOSS, Vector2(29, 19), game.host_id, 980)
		if once("clock", 60):
			game.start_at = game.network_step() - Rules.DEADLINE + 120
			game.update_run()
		if game.step >= Rules.DEADLINE:
			game.update_run()

func win_step() -> void:
	if once("kit", 0):
		for player: int in game.motions:
			if game.host:
				game.pending_rounds[player] = 1
	if once("fixture", 10):
		add_stone(91, Vector2(-4, 0), 42)
	if game.host and once("xp", 60):
		game.claim(91)
	if not game.host and once("selection_start", 94):
		selection_start = game.motions[game.local_id].position_xz
	for index in 3:
		if once("upgrade" + str(index), 110 + index * 45):
			game.pick_upgrade(index)
	if not game.host and once("selection_motion", 138):
		check(game.motions[game.local_id].position_xz.distance_to(selection_start) > 2.0,
			"guest keeps moving during the first upgrade round")
	if game.host and once("boss", 230):
		game.spawn_enemy(State.Species.BOSS, Vector2(0, 0), game.host_id, 25)
	if once("lightning", 325) and not game.host:
		var mine: State = game.motions[game.local_id]
		game.battle.start_attack(Rules.Weapon.LIGHTNING, mine.position_xz, mine.facing, game.step)
	if game.host and game.boss_id > 0 and health(game.boss_id) == 0:
		game.update_run()

func settled() -> void:
	if not active or completed:
		return
	if once("finish_time", 0):
		measure_from = Time.get_ticks_msec()
	if Time.get_ticks_msec() - measure_from < 900:
		return
	var expected := {"win": Rules.Result.VICTORY, "down": Rules.Result.DOWN, "timeout": Rules.Result.TIMEOUT}
	if expected.has(test):
		check(game.result == expected[test], "expected result")
	if test == "win":
		for player: int in game.motions:
			check(Array(game.build_for(player).slice(1, 4)) == [1, 1, 1], "each weapon upgraded once")
		check(health(game.boss_id) == 0, "victory requires boss at zero HP")
	if test == "timeout":
		check(health(game.boss_id) > 0, "boss still alive at deadline")
	if test == "down":
		check(game.vitals[game.local_id].hp == 0, "local health reached zero")
	if test == "natural":
		check(marks.has("second_wave") and marks.has("boss_phase"), "natural run reached all three phases")
	summary()

func drain_message(sender: int, code: int) -> void:
	if test != "rules" and (test != "capacity" or not sampled):
		return
	if code == Wire.Code.BENCH_DRAINED and game.host and sender == game.guest_id:
		remote_drained = true
	if code == Wire.Code.BENCH_DONE and not game.host and sender == game.host_id:
		summary_after_ms = Time.get_ticks_msec() + 700

func frame(_delta: float) -> void:
	if not active or completed:
		return
	if summary_after_ms > 0 and Time.get_ticks_msec() >= summary_after_ms:
		summary()
		return
	var now := Time.get_ticks_usec()
	if args.has("capture") and not once_frame and not game.arena.headless and game.step >= int(args["capture"]):
		once_frame = true
		game.get_viewport().get_texture().get_image().save_png(args["output"] + ".png")
	for started in pending_attack_frames:
		game.battle.attack_feedback.append(float(now - started) / 1000.0)
	pending_attack_frames.clear()
	if movement_started > 0 and (game.arena.frame_position - started_at_position).dot(started_axis) > 0.01:
		motion_times.append(float(now - movement_started) / 1000.0)
		movement_started = 0
	if boot_time > 0 and Time.get_ticks_msec() - boot_time > 1000.0 * maxf(40.0, warmup + duration + 18.0) and test != "natural":
		check(false, "probe timed out")
		summary()
	var frame_ms := float(now - last_frame_at) / 1000.0
	last_frame_at = now
	if test != "capacity" or game.step < collect_after or collect_after == 0 or sampled:
		return
	var transport := Netcode.get_transport_stats()
	if frames.is_empty():
		mark = counters()
		mark.clock = now
		mark.epoch = Time.get_unix_time_from_system()
		game.battle.confirmations_local.clear()
		game.battle.confirmations_remote.clear()
		game.battle.received_hit_batch_sizes.clear()
		game.battle.attack_feedback.clear()
		motion_times.clear()
	frames.append(frame_ms)
	if game.step >= next_measure:
		next_measure = game.step + 6
		var owned := 0
		var direct_proxies := 0
		for enemy: State in game.enemies.values():
			if enemy.sync.is_write_ready():
				owned += 1
			elif enemy.source_step > 0:
				direct_proxies += int(enemy.sync.is_proxy_changes_only_enabled())
				var age := maxf(0.0, (game.step - enemy.source_step) * 1000.0 / Rules.HZ)
				age_seen += 1
				if ages.size() < 8192:
					ages.append(age)
				else:
					var slot := age_rng.randi_range(0, age_seen - 1)
					if slot < ages.size():
						ages[slot] = age
		ownership.append(owned)
		direct_proxy_count = direct_proxies
		visible.append(game.arena.visible_enemies)
		population.append(game.battle.book.alive_count)
		rtts.append(Netcode.get_rtt() * 1000.0)
		queue_bytes.append(int(transport.get("queued_bytes", 0)))
	rows.append([game.step, frame_ms, game.arena.visible_enemies, game.battle.pending.size(), int(transport.get("queued_bytes", 0))])
	mark.last = counters()
	mark.last_clock = now
	mark.last_epoch = Time.get_unix_time_from_system()

func counters() -> Dictionary:
	return {"ai": game.ai_us, "combat": game.combat_us, "fx": game.arena.fx_us,
		"message": game.channel.message_us, "sent": game.channel.sent, "received": game.channel.received, "hits": game.battle.book.applied_count}

func summary() -> void:
	if completed:
		return
	completed = true
	var root: String = args.get("output", "")
	var peak: Dictionary = Netcode.get_transport_stats()
	var window_size := DisplayServer.window_get_size()
	var motion_summary := enemy_motion.summary()
	if native_smoothing:
		# Netcode writes the presented value into the replicated property itself.
		motion_summary.erase("visible_to_snapshot_cm")
	var stats := {"role": "host" if game.host else "guest", "mode": ["A", "B", "C"][game.mode],
		"godot": Engine.get_version_info().string, "sdk": FileAccess.get_file_as_string("res://addons/netcode/build-id.txt").strip_edges(),
		"adapter": RenderingServer.get_video_adapter_name(), "scenario": scenario, "case": test,
		"display": DisplayServer.get_name(), "renderer": RenderingServer.get_current_rendering_method(),
		"window_size": [window_size.x, window_size.y],
		"max_fps": Engine.max_fps, "physics_hz": Engine.physics_ticks_per_second,
		"size": count, "step": game.step, "seed": seed, "simple": simple,
		"result": game.result, "errors": errors, "alive": game.battle.book.alive_count,
		"xp": game.battle.book.experience, "xp_version": game.battle.book.xp_version, "deaths": game.battle.book.deaths.size(),
		"hits": game.battle.book.applied_count, "duplicate_requests": game.battle.book.duplicates,
		"pending_hits": game.battle.pending.size(), "old_commits": game.battle.dropped_old_commits,
		"handoffs": game.handoffs, "hp_digest": ledger_digest(), "boss_hp": health(game.boss_id),
		"frame_ms": percentiles(frames), "move_ms": percentiles(motion_times), "attack_ms": percentiles(game.battle.attack_feedback),
		"hit_effect_ms": percentiles(hit_feedback), "room_clock_peer_minus_local_ms": clock_samples,
		"raw_enemies": raw_enemies and not native_smoothing, "netcode_smoothing": native_smoothing,
		"direct_proxy_count": direct_proxy_count, "enemy_motion": motion_summary,
		"local_confirmation_ms": percentiles(game.battle.confirmations_local), "remote_confirmation_ms": percentiles(game.battle.confirmations_remote),
		"rpc_batch_targets": percentiles(game.battle.received_hit_batch_sizes), "write_wait_ms": percentiles(game.write_waits),
		"danger_reaction_ms": percentiles(game.battle.danger_reaction), "late_dangers": game.battle.late_dangers,
		"state_age_ms": percentiles(ages), "rtt_ms": percentiles(rtts), "queued_bytes": percentiles(queue_bytes),
		"peak_queued_bytes": peak.get("provider_peak_queued_bytes", 0), "rpc_rejected": game.channel.rejected,
		"snapshot_backpressure_skips": peak.get("snapshot_backpressure_skips", 0),
		"snapshot_soft_skips": peak.get("snapshot_soft_skips", 0),
		"snapshot_budget_yields": peak.get("snapshot_budget_yields", 0),
		"authority_ack_coalesces": peak.get("authority_ack_coalesces", 0),
		"rpc_backlog": game.channel.backlog(), "rpc_backlog_peak": game.channel.queue_peak,
		"rpc_queue_peak_age_ms": game.channel.peak_queue_age_ms, "movement_coalesced": game.channel.movement_coalesced,
		"claim_rejections": game.claim_rejections, "upgrade_rejections": game.upgrade_rejections,
		"timed_out_hits": game.battle.timed_out_hits, "deferred_attack_steps": game.battle.deferred_attack_steps,
		"engine_static_memory_peak": int(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)),
		"owned": percentiles(ownership), "visible": percentiles(visible), "population": percentiles(population)}
	if mark.has("last"):
		var seconds: float = float(mark.last_clock - mark.clock) / 1000000.0
		stats.seconds = seconds
		stats.epoch_start = mark.epoch
		stats.epoch_end = mark.last_epoch
		for key in mark.last:
			stats[key + "_per_sec"] = (int(mark.last[key]) - int(mark[key])) / maxf(0.001, seconds)
	if not root.is_empty():
		var output := FileAccess.open(root + ".json", FileAccess.WRITE)
		if output != null:
			output.store_string(JSON.stringify(stats, "  "))
		var csv := FileAccess.open(root + ".csv", FileAccess.WRITE)
		if csv != null:
			csv.store_line("step,frame_ms,visible,pending_hits,queued_bytes")
			for row in rows:
				csv.store_csv_line(PackedStringArray(row))
	print("HORDE_RESULT ", JSON.stringify(stats))
	get_tree_quit(1 if not errors.is_empty() else 0)

func ledger_digest() -> int:
	var ids: Array = game.battle.book.enemies.keys()
	ids.sort()
	var values := PackedInt32Array()
	for id: int in ids:
		values.append(id)
		values.append(health(id))
	return hash(values)

func get_tree_quit(code := 0) -> void:
	game.get_tree().quit(code)

func check(condition: bool, description: String) -> void:
	if not condition:
		errors.append(description)
		push_error(description)

static func percentiles(values: Array) -> Dictionary:
	if values.is_empty():
		return {}
	var ordered := values.duplicate()
	ordered.sort()
	var last := ordered.size() - 1
	return {"n": ordered.size(), "p50": ordered[roundi(last * 0.50)], "p95": ordered[roundi(last * 0.95)],
		"p99": ordered[roundi(last * 0.99)], "max": ordered[last]}
