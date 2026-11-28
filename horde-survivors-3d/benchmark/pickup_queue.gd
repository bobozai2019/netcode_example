extends SceneTree

const Rules = preload("res://combat/rules.gd")
const STONES := 240
const FIRST_STONE := 1000000
const TIMEOUT_MS := 25000

class PickupGame extends "res://arena/run.gd":
	var collected := 0
	var first_pickup_at := -1
	var all_picked_at := -1
	var first_upgrade_dropped := false

	func auto_attack() -> bool:
		return false

	func record_pickup(id: int, winner: int) -> void:
		var first_award := id >= FIRST_STONE and id < FIRST_STONE + STONES and winner == guest_id and not claimed.has(id)
		super.record_pickup(id, winner)
		if first_award:
			collected += 1
			if collected == 1:
				first_pickup_at = Time.get_ticks_msec()
			if collected == STONES:
				all_picked_at = Time.get_ticks_msec()

	func receive_upgrade(fields: PackedInt32Array) -> void:
		if not host and fields[1] == local_id and not first_upgrade_dropped:
			first_upgrade_dropped = true
			return
		super.receive_upgrade(fields)

func _initialize() -> void:
	call_deferred("play")

func play() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 4:
		push_error("The pickup queue fixture requires a role, port, address and output path.")
		quit(2)
		return
	var is_host := args[0] == "host"
	var scene: Node = load("res://arena/main.tscn").instantiate()
	scene.set_script(PickupGame)
	var game := scene as PickupGame
	root.add_child(game)
	current_scene = game
	var boot := Time.get_ticks_msec()
	game.open_room(is_host, "0.0.0.0" if is_host else args[2], int(args[1]), 2, Rules.Gameplay.STRESS_TEST)
	var placed_at := -1
	var chosen_at := -1
	var confirmed_at := -1
	var alive_peak := 0
	var queued_bytes_peak := 0
	while Time.get_ticks_msec() - boot < TIMEOUT_MS:
		await process_frame
		if not is_instance_valid(game):
			quit(2)
			return
		var now := Time.get_ticks_msec()
		alive_peak = maxi(alive_peak, game.battle.book.alive_count)
		queued_bytes_peak = maxi(queued_bytes_peak, int(Netcode.get_transport_stats().get("queued_bytes", 0)))
		if placed_at < 0 and now - boot >= (7300 if is_host else 7000) and game.motions.has(game.guest_id):
			var point: Vector2 = game.motions[game.guest_id].position_xz
			for offset in STONES:
				game.battle.book.stones[FIRST_STONE + offset] = {"position": point, "value": 1, "winner": 0}
			placed_at = Time.get_ticks_msec()
		if placed_at < 0:
			continue
		if is_host:
			if not game.members.has(game.guest_id):
				break
		else:
			if chosen_at < 0 and game.next_choice > 0:
				chosen_at = Time.get_ticks_msec()
				game.pick_upgrade(1)
			if chosen_at >= 0 and confirmed_at < 0 and game.build_for(game.local_id)[0] == 1:
				confirmed_at = Time.get_ticks_msec()
			if game.collected == STONES and confirmed_at >= 0 and alive_peak == Rules.STRESS_ENEMY_LIMIT and now - boot >= 16000:
				break

	var build: PackedInt32Array = game.build_for(game.guest_id)
	var ledger: Dictionary = game.battle.book.choices
	var report := {
		"role": args[0], "sdk": FileAccess.get_file_as_string("res://addons/netcode/build-id.txt").strip_edges(),
		"alive_peak": alive_peak, "collected": game.collected, "xp": game.battle.book.experience,
		"xp_version": game.battle.book.xp_version, "guest_build": Array(build), "upgrades": ledger.size(),
		"stones_placed_at_ms": placed_at - boot if placed_at >= 0 else null,
		"first_pickup_ms": game.first_pickup_at - placed_at if placed_at >= 0 and game.first_pickup_at >= placed_at else null,
		"all_pickups_ms": game.all_picked_at - placed_at if placed_at >= 0 and game.all_picked_at >= placed_at else null,
		"upgrade_confirmation_ms": confirmed_at - chosen_at if confirmed_at >= 0 else null,
		"first_upgrade_dropped": game.first_upgrade_dropped, "queued_bytes_peak": queued_bytes_peak,
		"rpc_backlog_peak": game.channel.queue_peak, "rpc_queue_peak_age_ms": game.channel.peak_queue_age_ms,
	}
	var passed: bool = (placed_at >= 0 and game.first_pickup_at >= placed_at and
		game.all_picked_at >= game.first_pickup_at and alive_peak == Rules.STRESS_ENEMY_LIMIT and game.collected == STONES and
		game.battle.book.experience == STONES and game.battle.book.xp_version == STONES and
		ledger.size() == 1 and build[0] == 1 and build[2] == 1)
	if not is_host:
		passed = passed and confirmed_at >= 0 and game.first_upgrade_dropped
	var output := FileAccess.open(args[3] + ".json", FileAccess.WRITE)
	if output != null:
		output.store_string(JSON.stringify(report, "  "))
		output.close()
	else:
		passed = false
	print("PICKUP_QUEUE_RESULT ", JSON.stringify(report))
	game.departing = true
	Netcode.leave_room()
	await create_timer(0.15).timeout
	quit(0 if passed else 1)
