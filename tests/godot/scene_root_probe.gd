extends SceneTree

var preview
var step := 0
var started := Time.get_ticks_msec()

func _initialize() -> void:
    preview = load("res://sync/sync_preview.tscn").instantiate()
    root.add_child(preview)

func _process(_dt: float) -> bool:
    if Time.get_ticks_msec() - started > 14000:
        for panel in [preview.host_panel, preview.guest_panel]:
            print(panel.name, " ", panel.score, " ", panel.get_node("Indicators/Lamp").visible, " ",
                panel.get_node("Mechanism/Marker").position, " rpc=", panel.local_calls)
        push_error("Preview did not converge at step %d" % step)
        quit(1)
        return false
    if not preview.is_node_ready() or preview.get_node("%Add").disabled: return false
    var host = preview.host_panel
    var guest = preview.guest_panel
    match step:
        0:
            var sync = host.get_node("Network/Sync")
            if not sync.reference() or sync.resolve_node(preview.host.node_reference(host)) != host:
                push_error("Network reference did not resolve to the scene root")
                quit(1)
                return false
            preview.get_node("%Add").pressed.emit()
            preview.get_node("%Lamp").pressed.emit()
            step = 1
        1:
            if _matches(guest, 1, false):
                preview.get_node("%Claim").pressed.emit()
                step = 2
        2:
            if guest.get_node("Network/Sync").is_write_ready():
                preview.get_node("%Add").pressed.emit()
                preview.get_node("%Lamp").pressed.emit()
                preview.get_node("%Send").pressed.emit()
                step = 3
        3:
            if _matches(host, 2, true) and host.local_calls == [[2, 1]] and guest.local_calls == [[2, 1]]:
                print("scene_root_pass fields=3 branches=2 authority_transfer=1 rpc=1 reference=1")
                quit()
    return false

func _matches(panel: Node, score: int, lamp: bool) -> bool:
    return (panel.score == score and panel.get_node("Indicators/Lamp").visible == lamp
        and panel.get_node("Mechanism/Marker").position.x == score)
