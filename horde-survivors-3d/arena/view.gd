extends Node3D

const State = preload("res://actors/state.gd")
const Rules = preload("res://combat/rules.gd")
const Soldier = preload("res://actors/soldier_view.gd")
const Batch = preload("res://actors/batch.gd")
const Effect = preload("res://effects/mesh_effect.gd")
const HUD = preload("res://ui/interface.gd")
const MotionMetrics = preload("res://benchmark/enemy_motion.gd")
@export var effect_scene: PackedScene
@export var enemy_hit_tint := Color.WHITE
@export var enemy_windup_tint := Color.WHITE
@export var stone_tint := Color.WHITE

var game
var simplified := false
var headless := false
var camera: Camera3D
var camera_offset := Vector3.ZERO
var effects: Node3D
var hud: HUD
var soldiers: Array[Soldier] = []
var enemy_batches: Array[Batch] = []
var stone_batch: MultiMeshInstance3D
var effect_pool: Array[Effect] = []
var active_effects: Array[Dictionary] = []
var damage_text: Array[Dictionary] = []
var visible_enemies := 0
var fx_us := 0
var frame_position := Vector2.ZERO
var debug_motion := MotionMetrics.new()
var debug_previous_frame_us := 0

func setup(session, simple: bool) -> void:
	game = session
	simplified = simple
	headless = DisplayServer.get_name() == "headless"
	var presentation := $Presentation
	if headless:
		presentation.queue_free()
		return
	camera = presentation.get_node("Camera")
	camera_offset = camera.position
	effects = presentation.get_node("Effects")
	hud = presentation.get_node("HUD")
	hud.game = game
	hud.set_debug_enabled(game.probe.args.has("debug"))
	soldiers = [presentation.get_node("Tide"), presentation.get_node("Ember")]
	var batches := presentation.get_node("Batches")
	enemy_batches = [batches.get_node("Grunt"), batches.get_node("Charger"), batches.get_node("Boss"), batches.get_node("Practice")]
	stone_batch = batches.get_node("Stones")
	if simplified:
		presentation.get_node("Sun").shadow_enabled = false
		for soldier in soldiers:
			soldier.use_simplified_rig()
		for batch in enemy_batches:
			batch.use_simplified_mesh()

func enter_match() -> void:
	if not headless:
		hud.enter_match()

func present(delta: float) -> void:
	var frame_us := Time.get_ticks_usec()
	if headless:
		if game.start_at > 0:
			for enemy: State in game.enemies.values():
				enemy.advance_enemy_pose(delta, frame_us, game.probe.raw_enemies)
		if game.motions.has(game.local_id):
			frame_position = game.motions[game.local_id].position_xz
		return
	hud.status.text = game.lobby_status
	if game.start_at <= 0:
		return
	for player: int in game.motions:
		if not game.vitals.has(player):
			continue
		var motion: State = game.motions[player]
		var life: State = game.vitals[player]
		var soldier := soldiers[motion.team]
		soldier.visible = game.members.has(player)
		soldier.present(motion, life, game.step, player == game.local_id, delta)
	update_camera()
	var started := Time.get_ticks_usec()
	if hud.show_debug:
		if debug_previous_frame_us > 0 and debug_motion.frames.size() < MotionMetrics.MAX_SAMPLES:
			debug_motion.frames.append(float(frame_us - debug_previous_frame_us) / 1000.0)
		debug_previous_frame_us = frame_us
	elif debug_previous_frame_us > 0:
		debug_motion.reset()
		debug_previous_frame_us = 0
	draw_entities(delta, frame_us)
	draw_effects()
	draw_damage()
	fx_us += Time.get_ticks_usec() - started
	hud.update_display(visible_enemies, debug_motion)

func update_camera() -> void:
	var focus: int = game.local_id
	if game.vitals.has(focus) and game.vitals[focus].hp <= 0:
		for player: int in game.members:
			if game.vitals.has(player) and game.vitals[player].hp > 0:
				focus = player
				break
	var motion: State = game.motions.get(focus)
	if motion != null:
		var soldier := soldiers[motion.team]
		frame_position = Vector2(soldier.position.x, soldier.position.z)
		camera.position = camera_offset + Rules.xz(frame_position)

func draw_entities(delta: float, frame_us: int) -> void:
	var count := PackedInt32Array([0, 0, 0, 0])
	visible_enemies = 0
	for enemy: State in game.enemies.values():
		enemy.advance_enemy_pose(delta, frame_us, game.probe.raw_enemies)
		var species := int(enemy.species)
		var pool := enemy_batches[species].multimesh
		var accepted: Dictionary = game.battle.book.enemies.get(enemy.entity_id, {})
		var point := enemy.observed_position()
		if int(accepted.get("hp", enemy.hp)) <= 0 or not on_screen(point, 2.0) or count[species] >= pool.instance_count:
			continue
		if enemy.is_visual_proxy and enemy.entity_id % 8 == 0:
			if hud.show_debug:
				debug_motion.observe(enemy, frame_us)
			game.probe.observe_enemy_motion(enemy, frame_us)
		var index := count[species]
		var direction := enemy.observed_facing()
		var angle := atan2(direction.x, direction.y)
		var at := Rules.xz(point)
		var transform := Transform3D(Basis(Vector3.UP, angle), at)
		pool.set_instance_transform(index, transform)
		var tint: Color = enemy_batches[species].tint
		if game.battle.hit_flashes.has(enemy.entity_id):
			tint = enemy_hit_tint
		elif enemy.windup_until > game.step:
			tint = enemy_windup_tint
		pool.set_instance_color(index, tint)
		count[species] += 1
		visible_enemies += 1
	for species in 4:
		enemy_batches[species].multimesh.visible_instance_count = count[species]
	var stones := stone_batch.multimesh
	var index := 0
	for id: int in game.battle.book.stones:
		var stone: Dictionary = game.battle.book.stones[id]
		if int(stone.winner) != 0 or not on_screen(stone.position, 0.7) or index >= stones.instance_count:
			continue
		var position := Rules.xz(stone.position, 0.42 + sin(game.step * 0.06 + id) * 0.12)
		stones.set_instance_transform(index, Transform3D(Basis(Vector3.UP, game.step * 0.04 + id), position))
		stones.set_instance_color(index, stone_tint)
		index += 1
	stones.visible_instance_count = index

func on_screen(point: Vector2, margin: float) -> bool:
	var viewport := get_viewport().get_visible_rect().size
	var width: float = camera.size * viewport.x / maxf(1.0, viewport.y)
	var delta := point - frame_position
	var pitch := maxf(0.01, absf(sin(camera.rotation.x)))
	return absf(delta.x) <= width / 2.0 + margin and absf(delta.y) <= camera.size / (2.0 * pitch) + margin

func draw_effects() -> void:
	var now: int = game.step
	for effect in effect_pool:
		effect.hide()
	var index := 0
	for knife: Dictionary in game.battle.flying:
		var axis: Vector2 = knife.axis
		var point: Vector2 = knife.origin + axis * (0.45 + float(knife.elapsed) * 0.42)
		if on_screen(point, 2.0):
			var tip := point + axis * 0.85
			effect_at(index).line(point - axis * 0.64, tip, 0.16, 0.56, Effect.Paint.KNIFE)
			index += 1
	for id: Vector2i in game.battle.hazards:
		var danger: Dictionary = game.battle.hazards[id]
		var warning := now < int(danger.active)
		var tint := Effect.Paint.WARNING if warning else Effect.Paint.DANGER
		if danger.origin == danger.end:
			effect_at(index).ring(danger.origin, float(danger.radius), 0.14, tint)
		else:
			var fill := Effect.Paint.WARNING_FILL if warning else Effect.Paint.DANGER_FILL
			effect_at(index).line(danger.origin, danger.end, 2.0 * float(danger.radius), 0.07, fill)
			index += 1
			effect_at(index).ring(danger.origin, float(danger.radius), 0.10, tint)
			index += 1
			effect_at(index).ring(danger.end, float(danger.radius), 0.10, tint)
		index += 1
	for i in range(active_effects.size() - 1, -1, -1):
		var fx := active_effects[i]
		if now >= fx.end_step:
			active_effects.remove_at(i)
			continue
		if not on_screen(fx.point, 5.0):
			continue
		if fx.has("end"):
			effect_at(index).line(fx.point, fx.end, 0.15, 0.68, fx.tint)
		else:
			effect_at(index).ring(fx.point, fx.radius, fx.height, fx.tint)
		if fx.has("feedback_started"):
			game.probe.hit_presented(fx.feedback_started)
			fx.erase("feedback_started")
		index += 1

func effect_at(index: int) -> Effect:
	while effect_pool.size() <= index:
		var fresh := effect_scene.instantiate() as Effect
		effects.add_child(fresh)
		effect_pool.append(fresh)
	return effect_pool[index]

func flash(point: Vector2, radius: float, height: float, tint: Effect.Paint, until: int, feedback_started := 0) -> void:
	if not headless and not simplified and active_effects.size() < 240:
		var fx := {"point": point, "radius": radius, "height": height, "tint": tint, "end_step": until}
		if feedback_started > 0 and game.probe.active:
			fx.feedback_started = feedback_started
		active_effects.append(fx)

func pulse(point: Vector2, radius: float, step: int) -> void:
	flash(point, radius, 0.12, Effect.Paint.HALO, step + 15)

func hit(point: Vector2, step: int, damage: int, hit_at: int) -> void:
	flash(point, 0.49, 0.48, Effect.Paint.HIT, step + 6, hit_at)
	if not headless and not simplified and damage_text.size() < hud.damage_labels.size() and on_screen(point, 1.0):
		damage_text.append({"point": point, "damage": damage, "start": step})

func fall(point: Vector2, step: int) -> void:
	flash(point, 0.85, 0.17, Effect.Paint.FALL, step + 11)

func arc(from: Vector2, to: Vector2, step: int) -> void:
	if not headless and not simplified and active_effects.size() < 240:
		active_effects.append({"point": from, "end": to, "tint": Effect.Paint.LIGHTNING, "end_step": step + 9})

func lightning(origin: Vector2, selected: Array[State], step: int) -> void:
	var p := origin
	for enemy in selected:
		var point := enemy.observed_position()
		arc(p, point, step)
		p = point

func suction(id: int, player: int, step: int) -> void:
	var stone: Dictionary = game.battle.book.stones.get(id, {})
	if not stone.is_empty() and game.motions.has(player):
		arc(stone.position, game.motions[player].position_xz, step)

func draw_damage() -> void:
	var number := 0
	for i in range(damage_text.size() - 1, -1, -1):
		var entry := damage_text[i]
		var age: int = game.step - entry.start
		if age >= 24:
			damage_text.remove_at(i)
			continue
		var marker := hud.damage_labels[number] as Label
		marker.position = camera.unproject_position(Rules.xz(entry.point, 1.16 + age * 0.045)) - Vector2(10, 24)
		marker.text = str(entry.damage)
		marker.modulate.a = minf(1.0, (24 - age) / 12.0)
		marker.show()
		number += 1
	for index in range(number, hud.damage_labels.size()):
		hud.damage_labels[index].hide()
