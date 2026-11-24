extends SceneTree
func _initialize() -> void:
    var root_node := Node3D.new()
    var exporter := preload("res://addons/netcode/layout_exporter.gd").new()
    root_node.add_child(exporter)
    exporter.schema_id = 23
    exporter.version = 2
    exporter.schema_name = "Mover"
    exporter.fields[1] = NodePath(".:position")
    var text := exporter.build_text(root_node)
    exporter.fields[2] = NodePath(".:missing_property")
    var rejected := exporter.build_text(root_node).is_empty()
    root_node.free()
    if text != "schema 23 2 Mover\nvec3 1 . position\n" or not rejected:
        quit(1)
    else:
        print("layout_export_pass schema=23 field=position")
        quit()
