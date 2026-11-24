extends Node

var host := OS.get_environment("NETCODE_RACING_ROLE") == "host"
var port := OS.get_environment("NETCODE_RACING_PORT").to_int()

func _ready() -> void:
    run.call_deferred()

func run() -> void:
    while get_tree().current_scene == null: await get_tree().process_frame
    var main := get_tree().current_scene
    main.get_node("%Port").value = port
    main.get_node("%Model").select(0 if host else 1)
    main.get_node("%Host" if host else "%Join").pressed.emit()
    print("racing_open role=%s port=%s" % ["host" if host else "guest", main.get_node("%Port").value])
    var verified := false
    var observation := ""
    var deadline := Time.get_ticks_msec() + 18000
    while Time.get_ticks_msec() < deadline:
        await get_tree().physics_frame
        var actors := main.get_node("Vehicles").get_children()
        if host and verified and actors.size() == 1 and actors[0].local_driver:
            print("racing_pass host remote_removed=1")
            get_tree().quit()
            return
        if actors.size() != 2: continue
        var own = actors[0] if actors[0].local_driver else actors[1]
        var other = actors[1] if actors[0].local_driver else actors[0]
        observation = str([own.scene_file_path, own.position, own.local_driver, other.scene_file_path, other.position, other.braking, other.get_node("Sync").has_authority()])
        if not own.local_driver or not own.get_node("Sync").is_write_ready(): continue
        if other.local_driver or other.get_node("Sync").has_authority(): continue
        var remote_scene := "roadster.tscn" if host else "vehicle.tscn"
        if not other.scene_file_path.ends_with(remote_scene): continue
        if host and own.position.x > 360 and other.braking and other.position.x < 200 and absf(other.position.y - 300) < 3:
            verified = true
        if not host and other.position.x > 260 and absf(other.position.y - 300) < 3:
            verified = true
        if host and verified: Input.action_release("drive_forward")
        Input.action_press("drive_forward" if host and not verified else "drive_reverse")
        if not host and verified and own.position.x < 105 and other.braking:
            main.get_node("%Leave").pressed.emit()
            print("racing_pass guest own_write=1 remote_motion=1")
            get_tree().quit()
            return
    push_error("Racing timed out: %s, nodes=%s, verified=%s, last=%s" % [main.get_node("UI/Status").text, main.get_node("Vehicles").get_child_count(), verified, observation])
    get_tree().quit(1)
