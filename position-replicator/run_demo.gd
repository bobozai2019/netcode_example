extends SceneTree

func _initialize() -> void:
    var status := GDExtensionManager.load_extension("res://position_replicator.gdextension")
    if status != GDExtensionManager.LOAD_STATUS_OK and status != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
        push_error("Could not load PositionReplicator: %s" % status)
        quit(1)
        return
    call_deferred("open_demo")

func open_demo() -> void:
    if change_scene_to_file("res://demo.tscn") != OK:
        quit(1)
