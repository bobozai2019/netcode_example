extends Node2D

const Paint = preload("res://yard/objects/paint.gd")
const Replicator = preload("res://yard/replicator.gd")
const Lobby = preload("res://yard/lobby/lobby.gd")

enum Template { CAR = 1, GATE, BEACON, BARRIER, LOAD, PROFILE }
enum Phase { CONNECTING, WAITING, PLAYING, ENDED }

const OBJECT_SCENES := {
    Template.CAR: preload("res://yard/objects/car.tscn"),
    Template.GATE: preload("res://yard/objects/gate.tscn"),
    Template.BEACON: preload("res://yard/objects/beacon.tscn"),
    Template.BARRIER: preload("res://yard/objects/barrier.tscn"),
    Template.LOAD: preload("res://yard/objects/load.tscn"),
    Template.PROFILE: preload("res://yard/objects/profile.tscn"),
}
const LAMP_SCENE := preload("res://yard/objects/lamp.tscn")

var bridge := NetcodeYard.new()
var options: Dictionary
var replicator: Replicator
@onready var world2: Node2D = $World2D
@onready var world3: Node3D = %World3D
@onready var status_label: Label = $Status
@onready var notice_label: Label = $Notice
var player_id := 0
var round_id := 0
var visual_logged := false
var local_authority_logged := false
var prediction_logged := false
var profile_logged := false
var profile_updated := false
var capturing := false
var lobby_captured := false
var close_at := 0
var barriers: Dictionary = {}
@onready var lobby: Lobby = $Lobby

func _ready() -> void:
    set_process(false)
    var error := bridge.configure(OS.get_cmdline_user_args(), FileAccess.get_file_as_string("res://replicators.cfg"))
    if not error.is_empty():
        push_error(error)
        get_tree().quit(1)
        return
    options = bridge.settings()
    get_tree().auto_accept_quit = false
    get_window().title = "Netcode Godot Car Yard"
    if options.smoke:
        await RenderingServer.frame_post_draw
        print("Godot scene rendered")
        get_tree().quit()
        return

    replicator = Replicator.new(bridge.bindings(), make_object)
    if options.binding_smoke:
        await RenderingServer.frame_post_draw
        var passed := verify_bindings()
        print("Godot 2D/3D transform, independent fields, child replacement, deletion ",
            "passed" if passed else "failed")
        get_tree().quit(0 if passed else 1)
        return
    if not options.scripted:
        lobby.configure(bridge, options.local_ip)
    set_process(true)

func make_object(snapshot: Dictionary) -> Node:
    var scene: PackedScene = OBJECT_SCENES.get(snapshot.schema, OBJECT_SCENES[Template.LOAD])
    var node := scene.instantiate()
    if snapshot.schema == Template.CAR:
        var car := node as Paint
        car.tint = Color("#5ce0bb") if player_id == snapshot.owner else (
            Color("#f9a569") if snapshot.owner == 1 else Color("#7caff6"))
    var parent: Node = world3 if snapshot.schema == Template.BEACON else world2
    parent.add_child(node)
    return node

func _unhandled_key_input(event: InputEvent) -> void:
    if options.is_empty() or options.scripted or options.smoke or options.binding_smoke:
        return
    var key := event as InputEventKey
    if key == null or not key.pressed or key.echo:
        return
    if lobby.visible and key.physical_keycode not in [KEY_F2, KEY_R]:
        return
    match key.physical_keycode:
        KEY_F2: bridge.act("start")
        KEY_F3: bridge.act("end_round")
        KEY_F4: bridge.act("disconnect")
        KEY_F5: bridge.act("authority_1")
        KEY_F6: bridge.act("authority_2")
        KEY_F7: bridge.act("authority_3")
        KEY_F8: bridge.act("cycle_driver")
        KEY_R: bridge.act("rejoin")
        KEY_E: bridge.act("gate")
        KEY_B: bridge.act("place")
        KEY_X: bridge.act("remove")
        KEY_H: bridge.act("horn")
        KEY_Q: close_room()

func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST and not options.is_empty():
        if options.smoke or options.binding_smoke:
            get_tree().quit(1)
        else:
            close_room()

func close_room() -> void:
    bridge.act("end_room")
    close_at = Time.get_ticks_msec() + 350

func _process(delta: float) -> void:
    var frame := bridge.advance()
    if frame.has("error"):
        push_error(frame.error)
        get_tree().quit(1)
        return
    var status: int = frame.get("status", -1)
    if status >= 0 or (close_at > 0 and Time.get_ticks_msec() >= close_at):
        get_tree().quit(maxi(status, 0))
        return
    if not options.scripted:
        lobby.show_frame(frame)
        if not lobby_captured and not options.lobby_capture.is_empty() and (frame.phase < 0 or frame.phase == Phase.WAITING):
            lobby_captured = true
            capture_frame(options.lobby_capture, "lobby_capture")
    if frame.phase < 0:
        get_window().title = "Netcode Godot Car Yard"
        return
    options.host = frame.host
    get_window().title = "Netcode Godot Car Yard - " + ("Host" if options.host else "Guest")
    if not options.scripted and frame.phase == Phase.PLAYING:
        if get_window().has_focus():
            var throttle := axis(KEY_W, KEY_UP) - axis(KEY_S, KEY_DOWN)
            var steer := axis(KEY_D, KEY_RIGHT) - axis(KEY_A, KEY_LEFT)
            bridge.drive(throttle, steer)
        else:
            bridge.drive(0.0, 0.0)
    player_id = frame.player
    if round_id != frame.round:
        replicator.sync([], false)
        barriers.clear()
        round_id = frame.round
    var own := replicator.node_for(frame.car) as Node2D
    var previous_x := own.position.x if own != null else 0.0
    replicator.sync(frame.objects, not options.host)
    replicator.render(delta)
    if options.trace:
        trace_visual(frame, previous_x)
    status_label.text = status_text(frame)
    notice_label.text = frame.notice
    if not capturing and not options.capture.is_empty() and frame.ready and frame.tick > 20:
        capturing = true
        capture_frame(options.capture, "render_capture")

func trace_visual(frame: Dictionary, previous_x: float) -> void:
    var current_barriers := {}
    for snapshot: Dictionary in frame.objects:
        if snapshot.schema == Template.PROFILE and not profile_updated:
            var profile := replicator.node_for(snapshot.id)
            if (not profile_logged and profile != null and profile.get_meta("score", 0) == 16777217
                    and profile.get_meta("player_name", "") == "玩家🚀" and profile.get_meta("inventory") == PackedInt32Array([7,-2,16777219])
                    and profile.get_meta("cursor") == Vector2(2,-3) and profile.get_meta("axis") == Vector3(4,5,-6)
                    and profile.get_meta("orientation") == Quaternion(0,0,1,0) and profile.get_meta("weights") == PackedFloat32Array([0.25,-0.5])):
                profile_logged = true
                print("typed_profile applied")
            if (profile != null and profile.get_meta("score", 0) == 16777219 and profile.get_meta("player_name", "") == "通关"
                    and profile.get_meta("inventory") == PackedInt32Array([7]) and profile.get_meta("weights") == PackedFloat32Array()):
                profile_updated = true
                print("typed_profile updated")
        if not visual_logged and snapshot.get("buffered", false):
            var remote := replicator.node_for(snapshot.id) as Node2D
            if remote != null and absf(remote.position.x - snapshot.public_x) > 0.02 and absf(remote.position.x - snapshot["values"][0]) < 0.02:
                visual_logged = true
                print("visual id=", snapshot.id, " display_x=", remote.position.x, " authority_x=", snapshot.public_x)
        if snapshot.schema == Template.BARRIER:
            current_barriers[snapshot.id] = true
            if not barriers.has(snapshot.id) and replicator.node_for(snapshot.id) != null:
                print("visual_created object=", snapshot.id)
        if options.host or not frame.ready or snapshot.id != frame.car or previous_x == 0.0:
            continue
        var node := replicator.node_for(snapshot.id) as Node2D
        var shown := node.position.x
        var authoritative: float = snapshot["values"][0]
        if snapshot.local_state and absf(shown - authoritative) < 0.02 and absf(shown - previous_x) > 0.02:
            if snapshot.predicted and not prediction_logged:
                prediction_logged = true
                print("visual prediction_local object=", snapshot.id)
            elif not snapshot.predicted and not local_authority_logged:
                local_authority_logged = true
                print("visual authority_local object=", snapshot.id)
    for id: int in barriers.keys():
        if not current_barriers.has(id) and replicator.node_for(id) == null:
            print("visual_removed object=", id)
    barriers = current_barriers

func capture_frame(path: String, result_name: String) -> void:
    await RenderingServer.frame_post_draw
    var image := get_viewport().get_texture().get_image()
    var passed := not image.is_empty() and image.save_png(path) == OK
    print(result_name + ("_ok" if passed else "_failed"))

static func axis(a: Key, b: Key) -> float:
    return 1.0 if Input.is_physical_key_pressed(a) or Input.is_physical_key_pressed(b) else 0.0

func status_text(frame: Dictionary) -> String:
    match frame.phase:
        Phase.CONNECTING: return "Connecting to host"
        Phase.WAITING:
            return str(frame.seats) + "/4 seats    " + ("F2  Start    Q  Close" if options.host else "Waiting for host")
        Phase.PLAYING:
            if not frame.ready:
                return "Applying current world"
            return "Player %s    Round %s    %s" % [
                frame.player, frame.round, "F5-F7  Guest authority    F8  Lend car    F3  End round    Q  Close" if options.host else "F4  Disconnect"]
        _:
            if options.host:
                return "Room closed"
            if frame.reject != 0:
                return "Join rejected    R  Retry"
            return "Host timed out    R  Reconnect" if frame.loss == 3 else "Disconnected    R  Reconnect"

func verify_bindings() -> bool:
    var car := {"id": 1, "schema": Template.CAR, "owner": 2, "revision": 1,
        "values": [110.0, 125.0, 45.0, 1.3, 1.5, 0.75, 0.5]}
    var beacon := {"id": 2, "schema": Template.BEACON, "owner": 0, "revision": 1,
        "values": [405.0, 340.0, 12.0, 16.0, 32.0, 46.0, 1.1, 1.2, 1.3, 1.0]}
    replicator.sync([car, beacon], false)
    replicator.render(0.0)
    var root := replicator.node_for(1) as Paint
    var lamp := root.get_node("lamp") as Paint
    var model := replicator.node_for(2).get_node("model") as MeshInstance3D
    if root == null or lamp == null or model == null:
        return false
    var passed := root.position.is_equal_approx(Vector2(110, 515)) and (
        root.scale.is_equal_approx(Vector2(1.3, 1.5))) and is_equal_approx(root.rotation_degrees, 45.0) and (
        is_equal_approx(root.net_input_x, 0.75)) and is_equal_approx(lamp.glow, 0.5) and (
        model.position.is_equal_approx(Vector3(405, 340, 12))) and (
        model.rotation_degrees.is_equal_approx(Vector3(16, 32, 46))) and (
        model.scale.is_equal_approx(Vector3(1.1, 1.2, 1.3)))
    car = car.duplicate(true)
    car.revision = 2
    car["values"][5] = -0.5
    replicator.sync([car, beacon], true)
    replicator.render(0.016)
    passed = passed and is_equal_approx(root.net_input_x, -0.5) and is_equal_approx(lamp.glow, 0.5)
    lamp.free()
    replicator.render(0.016)
    var replacement := LAMP_SCENE.instantiate() as Paint
    root.add_child(replacement)
    replicator.render(0.016)
    passed = passed and is_equal_approx(replacement.glow, 0.5)
    replicator.sync([beacon], true)
    return passed and root.get_parent() == null and replicator.node_for(1) == null and (
        replicator.node_for(2) != null)
