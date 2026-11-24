extends Control

enum Phase { SETUP = -1, CONNECTING, WAITING, PLAYING, ENDED }

var bridge: NetcodeYard
@onready var setup: Control = $Setup
@onready var room: Control = $Room
@onready var join_ip: LineEdit = %JoinIP
@onready var join_port: LineEdit = %JoinPort
@onready var host_port: LineEdit = %HostPort
@onready var port_choices: OptionButton = %PortChoices
@onready var feedback: Label = %Feedback
@onready var room_title: Label = %RoomTitle
@onready var endpoint_label: Label = %Endpoint
@onready var room_status: Label = %RoomStatus
@onready var room_feedback: Label = %RoomFeedback
@onready var room_actions: Button = %RoomActions
@onready var start_button: Button = %Start
@onready var player_labels: Array[Label] = [$Room/Player1, $Room/Player2, $Room/Player3, $Room/Player4]
@onready var kick_buttons: Array[Button] = [$Room/Kick1, $Room/Kick2, $Room/Kick3, $Room/Kick4]
@onready var chat_log: RichTextLabel = %ChatLog
@onready var chat_input: LineEdit = %ChatInput
@onready var chat_button: Button = %Send
var chat_lines := PackedStringArray()

func configure(adapter: NetcodeYard, local_ip: String) -> void:
	bridge = adapter
	%LocalIP.text = local_ip
	refresh_ports()
	show()

func _select_port(index: int) -> void:
	host_port.text = port_choices.get_item_text(index)

func _join(_value := "") -> void:
	enter(false)

func _host(_value := "") -> void:
	enter(true)

func _start() -> void:
	bridge.act("start")

func show_frame(frame: Dictionary) -> void:
	var phase: int = frame.phase
	visible = phase != Phase.PLAYING
	if not visible:
		return
	setup.visible = phase == Phase.SETUP or phase == Phase.ENDED
	room.visible = not setup.visible
	if setup.visible:
		if phase == Phase.ENDED and feedback.text.is_empty():
			feedback.text = frame.connection_status
		return
	feedback.text = ""
	var waiting := phase == Phase.WAITING
	room_title.text = ("Hosting room" if frame.host else "Room") if waiting else "Connecting"
	endpoint_label.text = frame.endpoint + ("     Room " + frame.room if waiting else "")
	room_status.text = ("%s / 4 seats" % frame.seats) if waiting else "Waiting for the host to respond"
	room_actions.text = "Leave room" if waiting else "Cancel"
	start_button.visible = waiting and frame.host
	chat_input.editable = waiting
	chat_button.disabled = not waiting
	for index in player_labels.size():
		var id: int = frame.players[index] if index < frame.players.size() else 0
		var name_text := "Host" if id == 1 else "Player %s" % id
		player_labels[index].text = name_text + ("  (you)" if id == frame.player else "") if id else ""
		kick_buttons[index].visible = waiting and frame.host and id > 1
		kick_buttons[index].set_meta("player", id)
	if frame.chat != chat_lines:
		chat_lines = frame.chat
		chat_log.text = "\n".join(chat_lines)

func refresh_ports() -> void:
	port_choices.clear()
	for port in bridge.ports():
		port_choices.add_item(port)
	if port_choices.item_count > 0:
		port_choices.select(0)
		host_port.text = port_choices.get_item_text(0)

func enter(host: bool) -> void:
	feedback.text = bridge.enter(host, join_ip.text.strip_edges(),
		(host_port.text if host else join_port.text).strip_edges())
	room_feedback.text = ""
	if feedback.text.is_empty():
		chat_input.clear()

func leave() -> void:
	bridge.leave()
	feedback.text = ""
	room_feedback.text = ""
	chat_input.clear()

func kick(index: int) -> void:
	bridge.kick(kick_buttons[index].get_meta("player"))

func send_chat(_value := "") -> void:
	if bridge.chat(chat_input.text.strip_edges()):
		chat_input.clear()
		room_feedback.text = ""
	else:
		room_feedback.text = "Enter a message of up to 512 UTF-8 bytes."
