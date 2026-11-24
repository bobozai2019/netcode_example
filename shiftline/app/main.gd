extends Node

const Rules = preload("../net/config.gd")
const Match = preload("../net/match.gd")
const MatchScene = preload("../net/match.tscn")
const Interface = preload("../ui/interface.gd")
const Viewmodel = preload("../actors/viewmodel/viewmodel.gd")
const FirstPersonScene = preload("../actors/viewmodel/first_person.tscn")
const LOOK_SENSITIVITY := 0.00255

@onready var hud: Interface = $Interface
var match_state: Match
var camera: Camera3D
var viewmodel: Viewmodel
var aim_yaw := 0.0
var aim_pitch := 0.0
var tracked_life := -1
var tracked_round := -1
var move_seq := 0
var request_seq := 0
var input_sample := 0
var input_enabled := false
var trigger := false
var queued: Array[int] = []

func _ready() -> void:
	hud.connect_requested.connect(open_room)
	hud.cancel_requested.connect(leave_room.bind("Connection canceled."))
	hud.continue_requested.connect(set_menu.bind(false))
	hud.leave_requested.connect(leave_room.bind("You left the room."))
	hud.quit_requested.connect(get_tree().quit)
	if "--smoke" in OS.get_cmdline_user_args():
		print("shiftline_smoke lobby ready")
		get_tree().quit()

func open_room(host: bool, address: String, port: int, nickname: String) -> void:
	if match_state:
		return
	hud.connecting(true)
	match_state = MatchScene.instantiate() as Match
	add_child(match_state)
	var reason := match_state.connect_room(host, address, port, nickname)
	if not reason.is_empty():
		leave_room(reason)
		return
	match_state.ready_to_play.connect(enter_match)
	match_state.ended.connect(leave_room.call_deferred)
	match_state.hit_confirmed.connect(func() -> void: hud.marker_until = match_state.now + 0.18)
	match_state.feedback.connect(func(message: String) -> void: hud.show_feedback(message, match_state.now))

func enter_match() -> void:
	hud.show_game()
	camera = FirstPersonScene.instantiate() as Camera3D
	match_state.add_child(camera)
	camera.make_current()
	viewmodel = camera.get_node("Viewmodel") as Viewmodel
	tracked_round = -1
	tracked_life = -1
	update_view(0.0)
	set_menu(false)

func leave_room(message: String) -> void:
	input_enabled = false
	trigger = false
	queued.clear()
	if is_instance_valid(match_state):
		match_state.close()
		remove_child(match_state)
		match_state.queue_free()
		match_state = null
	camera = null
	viewmodel = null
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	hud.show_lobby(message)

func set_menu(open: bool) -> void:
	if not camera:
		return
	if open:
		hud.root.show()
		halt_input()
	hud.menu.visible = open
	input_enabled = not open
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if open else Input.MOUSE_MODE_CAPTURED
	if not open and get_viewport().gui_get_focus_owner():
		get_viewport().gui_release_focus()

func halt_input() -> void:
	queued.clear()
	if trigger:
		queued.append(Rules.Request.FIRE_STOP)
	trigger = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_instance_valid(camera):
		set_menu(true)

func _input(event: InputEvent) -> void:
	if not hud:
		return
	if event.is_action_pressed("toggle_interface"):
		hud.root.visible = not hud.root.visible
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("room_menu"):
		if camera:
			set_menu(not hud.menu.visible or not hud.root.visible)
		else:
			hud.root.show()
			if match_state: leave_room("Connection canceled.")
		get_viewport().set_input_as_handled()
	elif camera and event.is_action_pressed("roster"):
		hud.roster.visible = not hud.roster.visible
		get_viewport().set_input_as_handled()
	elif input_enabled:
		if event is InputEventMouseMotion:
			aim_yaw = wrapf(aim_yaw - event.relative.x * LOOK_SENSITIVITY, -PI, PI)
			aim_pitch = clampf(aim_pitch - event.relative.y * LOOK_SENSITIVITY, -1.42, 1.42)
		elif event.is_action_pressed("fire"):
			trigger = true
			queued.append(Rules.Request.FIRE_START)
		elif event.is_action_released("fire"):
			trigger = false
			queued.append(Rules.Request.FIRE_STOP)
		elif event.is_action_pressed("reload"):
			queued.append(Rules.Request.RELOAD)
		elif event.is_action_pressed("throw"):
			queued.append(Rules.Request.THROW)
		elif event.is_action_pressed("pickup"):
			queued.append(Rules.Request.PICKUP)
		else:
			return
		get_viewport().set_input_as_handled()

func _physics_process(_delta: float) -> void:
	if not camera or not match_state.local_slot:
		return
	var slot := match_state.local_slot
	if slot.life_id != tracked_life or match_state.match_id != tracked_round:
		sync_view()
	if not slot.alive or match_state.phase != Rules.Phase.PLAY:
		queued.clear()
		trigger = false
		return
	var axes := Vector2.ZERO
	var buttons := 0
	if input_enabled:
		axes = Input.get_vector("walk_left", "walk_right", "walk_forward", "walk_back")
		if Input.is_action_pressed("duck"): buttons |= Rules.Buttons.CROUCH
		if Input.is_action_pressed("jump"): buttons |= Rules.Buttons.JUMP
		if trigger: buttons |= Rules.Buttons.FIRE
	input_sample += 1
	if match_state.is_host or input_sample % 2 == 0 or not queued.is_empty():
		move_seq += 1
		match_state.send_move(slot.life_id, move_seq, buttons, axes, aim_yaw, aim_pitch)
	var actions := queued.duplicate()
	queued.clear()
	for kind: int in actions:
		var target := -1
		var generation := -1
		if kind == Rules.Request.PICKUP:
			var pickup := match_state.nearest_pickup(slot)
			if not pickup:
				continue
			target = pickup.map_id
			generation = pickup.generation
		request_seq += 1
		var aim := Basis.from_euler(Vector3(aim_pitch, aim_yaw, 0)) * Vector3.FORWARD
		match_state.send_action(slot.life_id, request_seq, kind, target, generation, aim)

func sync_view() -> void:
	var slot := match_state.local_slot
	aim_yaw = slot.yaw
	aim_pitch = slot.pitch
	tracked_life = slot.life_id
	tracked_round = match_state.match_id
	move_seq = 0
	request_seq = 0
	queued.clear()
	trigger = false
	camera.global_position = slot.global_position + Vector3.UP * slot.eye_height()

func _process(delta: float) -> void:
	if camera and match_state.local_slot:
		update_view(delta)
		hud.render(match_state)

func update_view(delta: float) -> void:
	var slot := match_state.local_slot
	if slot.life_id != tracked_life or match_state.match_id != tracked_round:
		sync_view()
	var point := slot.global_position + Vector3.UP * (slot.eye_height() if slot.alive else 0.45)
	camera.global_position = camera.global_position.lerp(point, 1.0 - exp(-delta * 24))
	camera.rotation = Vector3(aim_pitch if slot.alive else -0.13, aim_yaw, 0)
	viewmodel.visible = slot.alive and match_state.phase == Rules.Phase.PLAY
	if viewmodel.visible:
		viewmodel.animate(delta, slot.team, slot.pose, slot.action, slot.action_seq, match_state.now, slot.action_until)
