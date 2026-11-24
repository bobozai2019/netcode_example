extends CanvasLayer

signal connect_requested(host: bool, address: String, port: int, profile: String)
signal cancel_requested
signal continue_requested
signal leave_requested
signal quit_requested

const Rules = preload("../net/config.gd")
const RosterRow = preload("hud/roster_row.tscn")

@onready var root: Control = $Root
@onready var lobby: Control = $Root/Lobby
@onready var game: Control = $Root/Game
@onready var menu: Control = $Root/Game/Menu
@onready var roster: Control = $Root/Game/Roster
@onready var results: Control = $Root/Game/Results
@onready var crosshair: Label = $Root/Game/Crosshair
@onready var marker: Label = $Root/Game/Marker
@onready var form: VBoxContainer = $Root/Lobby/Content/ConnectionPanel/ConnectionForm
@onready var address: LineEdit = form.get_node("Endpoint/Destination/Address")
@onready var host_address: OptionButton = form.get_node("HostAddress")
@onready var port_input: LineEdit = form.get_node("Endpoint/Port/PortInput")
@onready var profile: LineEdit = form.get_node("Profile")
@onready var host_button: Button = form.get_node("Actions/HostButton")
@onready var join_button: Button = form.get_node("Actions/JoinButton")
@onready var cancel_button: Button = form.get_node("CancelButton")
@onready var status: Label = form.get_node("Status")
@onready var endpoint: Label = $Root/Game/TopBar/Status/Endpoint
@onready var scores: Label = $Root/Game/TopBar/Status/Scores
@onready var occupants: Label = $Root/Game/TopBar/Status/Occupants
@onready var health: Label = $Root/Game/HealthPanel/Health
@onready var ammo: Label = $Root/Game/LoadoutPanel/Loadout/Ammo
@onready var supplies: Label = $Root/Game/LoadoutPanel/Loadout/Supplies
@onready var hint: Label = $Root/Game/Hint
@onready var winner_label: Label = $Root/Game/Results/ResultsPanel/Outcome/WinnerLabel
@onready var countdown: Label = $Root/Game/Results/ResultsPanel/Outcome/Countdown
@onready var table: VBoxContainer = $Root/Game/Roster/RosterPanel/Table/Entries

var roster_signature := ""
var feedback_until := 0.0
var marker_until := 0.0

func _ready() -> void:
	for ip in lan_addresses():
		host_address.add_item(ip)
	port_input.text = str(Rules.DEFAULT_PORT)
	port_input.placeholder_text = port_input.text
	host_button.pressed.connect(submit.bind(true))
	join_button.pressed.connect(submit.bind(false))
	address.text_submitted.connect(func(_value: String) -> void:
		if not join_button.disabled: submit(false))
	cancel_button.pressed.connect(cancel_requested.emit)
	form.get_node("QuitButton").pressed.connect(quit_requested.emit)
	$Root/Game/Menu/MenuPanel/MenuItems/ContinueButton.pressed.connect(continue_requested.emit)
	$Root/Game/Menu/MenuPanel/MenuItems/LeaveButton.pressed.connect(leave_requested.emit)
	show_lobby("")

func lan_addresses() -> Array[String]:
	var local: Array[String] = []
	var other: Array[String] = []
	for ip: String in IP.get_local_addresses():
		if ip.contains(":") or ip.begins_with("127.") or ip.begins_with("169.254.") or ip.begins_with("198.18."):
			continue
		if ip.begins_with("192.168.") or ip.begins_with("10.") or (ip.begins_with("172.") and ip.get_slice(".", 1).to_int() in range(16, 32)):
			local.append(ip)
		else:
			other.append(ip)
	return local + other + ["127.0.0.1"]

func submit(host: bool) -> void:
	var ip := host_address.get_item_text(host_address.selected) if host else address.text.strip_edges()
	var port_text := port_input.text.strip_edges()
	if not port_text.is_valid_int() or not port_text.to_int() in range(1, 65536):
		status.text = "Enter a port from 1 to 65535."
	elif not ip.is_valid_ip_address() or ip.contains(":") or ip == "0.0.0.0":
		status.text = "Enter the host’s IPv4 address."
	else:
		connect_requested.emit(host, ip, port_text.to_int(), profile.text)

func show_lobby(message: String) -> void:
	root.show()
	lobby.show()
	game.hide()
	roster.hide()
	menu.hide()
	results.hide()
	connecting(false)
	status.text = message

func connecting(pending: bool) -> void:
	host_button.disabled = pending
	join_button.disabled = pending
	host_address.disabled = pending
	address.editable = not pending
	port_input.editable = not pending
	profile.editable = not pending
	cancel_button.visible = pending
	status.text = "Connecting to room…" if pending else ""

func show_game() -> void:
	connecting(false)
	game.show()
	lobby.hide()
	roster.hide()
	menu.hide()
	results.hide()
	marker_until = 0.0
	feedback_until = 0.0
	roster_signature = ""

func render(match_state: Node) -> void:
	var slot = match_state.local_slot
	if not slot:
		return
	var now: float = match_state.now
	endpoint.text = "%s:%d" % [match_state.host_ip, match_state.port]
	scores.text = "TIDE   %02d  /  %02d   EMBER" % [match_state.score_a, match_state.score_b]
	occupants.text = "%d / %d   PLAYERS" % [match_state.seats, Rules.CAPACITY]
	health.text = "%03d  HP" % slot.hp
	health.add_theme_color_override("font_color", Rules.team_color(slot.team) if slot.hp > 25 else Color("#ff8780"))
	ammo.text = "%02d  /  %03d" % [slot.magazine, slot.reserve]
	supplies.text = "%d GRENADE%s" % [slot.grenades, "" if slot.grenades == 1 else "S"]
	results.visible = match_state.phase == Rules.Phase.RESULTS
	if results.visible:
		winner_label.text = "%s WINS" % Rules.TEAM_NAMES[clampi(match_state.winner, 0, 1)]
		winner_label.add_theme_color_override("font_color", Rules.team_color(match_state.winner))
		countdown.text = "Next round in %d" % maxi(0, ceili(match_state.restart_at - now))
	crosshair.visible = slot.alive and not results.visible
	marker.visible = crosshair.visible and now < marker_until
	if not slot.alive and not results.visible:
		hint.text = "Returning in %d" % maxi(0, ceili(slot.respawn_at - now))
	elif slot.action == Rules.Action.RELOAD:
		hint.text = "Reloading…"
	elif now >= feedback_until:
		var pickup: Node = match_state.nearest_pickup(slot)
		hint.text = ("E   Take ammo" if pickup.kind == Rules.Pickup.AMMO else "E   Take grenade") if pickup else ""
	if roster.visible:
		var entries: Array = []
		for member in match_state.slots:
			if member.active:
				entries.append([member.team, member.nickname, member.kills, member.deaths, member.ping_ms, member.player_id])
		entries.sort_custom(func(a: Array, b: Array) -> bool:
			return a[0] < b[0] if a[0] != b[0] else a[5] < b[5])
		var signature := str(entries)
		if signature != roster_signature:
			roster_signature = signature
			for item in table.get_children():
				table.remove_child(item)
				item.queue_free()
			for entry: Array in entries:
				table_line([Rules.TEAM_NAMES[entry[0]], entry[1], str(entry[2]), str(entry[3]),
					"%d ms" % entry[4] if entry[4] >= 0 else "—"], Rules.team_color(entry[0]))

func table_line(cells: Array, color: Color) -> void:
	var line := RosterRow.instantiate() as HBoxContainer
	var labels := line.get_children()
	for index in cells.size():
		var cell := labels[index] as Label
		cell.text = cells[index]
	(labels[0] as Label).add_theme_color_override("font_color", color)
	table.add_child(line)

func show_feedback(message: String, now: float) -> void:
	hint.text = message
	feedback_until = now + 1.25
