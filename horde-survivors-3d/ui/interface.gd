extends CanvasLayer

const State = preload("res://actors/state.gd")
const Rules = preload("res://combat/rules.gd")
const MotionMetrics = preload("res://benchmark/enemy_motion.gd")

@onready var address: LineEdit = %Address
@onready var port: SpinBox = %Port
@onready var mode_select: OptionButton = %Mode
@onready var status: Label = %Status
@onready var lobby: PanelContainer = %Lobby
@onready var display: Control = %Display
@onready var clock: Label = %Clock
@onready var mission: Label = %Mission
@onready var kit: Label = %Kit
@onready var exp_bar: ProgressBar = %XPBar
@onready var exp_label: Label = %XPLabel
@onready var options: PanelContainer = %Options
@onready var upgrade_title: Label = %UpgradeTitle
@onready var outcome: PanelContainer = %Outcome
@onready var outcome_title: Label = %OutcomeTitle
@onready var debug_label: Label = %Debug
@onready var vitals_label: Array[Label] = [%TideName, %EmberName]
@onready var health: Array[ProgressBar] = [%TideHealth, %EmberHealth]
@onready var damage_labels: Array[Node] = %DamageLayer.get_children()

var game
var show_debug := false
var debug_update := 0

func enter_match() -> void:
	lobby.hide()
	display.show()

func host_room() -> void:
	game.open_room(true, "0.0.0.0", int(port.value), mode_select.selected)

func join_room() -> void:
	game.open_room(false, address.text.strip_edges(), int(port.value), mode_select.selected)

func leave_room() -> void:
	game.close_room()

func choose_weapon(option: int) -> void:
	game.pick_upgrade(option)

func update_display(visible_enemies: int, motion_metrics: MotionMetrics) -> void:
	var remain := maxi(0, ceili((Rules.DEADLINE - game.step) / 60.0))
	clock.text = "%02d:%02d" % [remain / 60, remain % 60]
	var phase := "SURVIVE THE SWARM"
	if game.step >= 300 * Rules.HZ:
		var enemy: State = game.enemies.get(game.boss_id)
		phase = "BREAK THE SIEGE"
		if enemy != null:
			phase += "   •   BOSS %d HP" % int(game.battle.book.enemies.get(game.boss_id, {}).get("hp", enemy.hp))
	elif game.step >= 120 * Rules.HZ:
		phase = "DODGE THE CHARGERS"
	mission.text = ["A", "B", "C"][game.mode] + "   /   " + phase
	for player: int in game.vitals:
		var life: State = game.vitals[player]
		var name := "TIDE" if life.team == 0 else "EMBER"
		var marker := "YOU · " if player == game.local_id else ""
		var state := "%d HP" % life.hp
		if not game.members.has(player):
			state = "DISCONNECTED"
		elif life.hp <= 0:
			state = "DOWN"
		vitals_label[life.team].text = marker + name + "   /   " + state
		health[life.team].value = life.hp
	var build: PackedInt32Array = game.build_for(game.local_id)
	kit.text = "KNIFE %d     HALO %d     STORM %d" % [build[1] + 1, build[2], build[3]]
	exp_label.text = "TEAM LEVEL %d   /   %d XP" % [game.battle.book.level + 1, game.battle.book.experience]
	exp_bar.max_value = Rules.threshold(game.battle.book.level)
	exp_bar.value = game.battle.book.unspent_experience
	var life: State = game.vitals.get(game.local_id)
	options.visible = game.next_choice > 0 and game.result == Rules.Result.LIVE and life != null and life.hp > 0
	if options.visible:
		upgrade_title.text = "Team level %d  ·  Choose one" % (game.next_choice + 1)
	outcome.visible = game.result != Rules.Result.LIVE
	if outcome.visible:
		outcome_title.text = ["", "Siege broken", "Both survivors fell", "Time ran out"][game.result]
	if show_debug and game.step >= debug_update:
		var owned := 0
		var waiting := 0
		for enemy: State in game.enemies.values():
			owned += int(enemy.sync.is_write_ready())
			waiting += int(enemy.waiting)
		debug_label.text = "%d visible · %d owned · %d delegated · %d baseline waits · %d handoffs · %d hits pending · %.1f ms RTT" % [
			visible_enemies, owned, game.enemies.size() - owned - waiting, waiting, game.handoffs, game.battle.pending.size(), Netcode.get_rtt() * 1000.0]
		var motion := motion_metrics.summary()
		var frame := MotionMetrics.percentiles(motion_metrics.frames)
		debug_label.text += "\nFPS %d  ·  Frame P95 %s ms  ·  Monster update P95 %s ms  ·  Step P95 %s cm  ·  Held %s%%" % [
			Engine.get_frames_per_second(), reading(frame.get("p95")), reading(motion.snapshot_spacing_ms.get("p95")),
			reading(motion.visible_motion_step_cm.get("p95")), reading(motion.held_percent)]
		motion_metrics.reset()
		debug_update = game.step + Rules.HZ

func reading(value: Variant) -> String:
	return "—" if value == null else "%.1f" % float(value)

func set_debug_enabled(enabled: bool) -> void:
	show_debug = enabled
	debug_label.visible = enabled

func _unhandled_key_input(event: InputEvent) -> void:
	if game == null or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode == KEY_F3:
		set_debug_enabled(not show_debug)
	if options.visible and event.physical_keycode in [KEY_1, KEY_2, KEY_3]:
		game.pick_upgrade(event.physical_keycode - KEY_1)
