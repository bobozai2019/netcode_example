@tool
extends EditorPlugin
func _enter_tree(): _test.call_deferred()
func _fail(msg):
    push_error(msg)
    get_tree().quit(1)
func _select(node: Node):
    EditorInterface.get_selection().clear()
    EditorInterface.get_selection().add_node(node)
    EditorInterface.edit_node(node)
    for i in 5: await get_tree().process_frame

func _visible_panel():
    for control in EditorInterface.get_base_control().find_children("*", "VBoxContainer", true, false):
        if control.get_script() and control.get_script().resource_path.ends_with("/field_panel.gd") and control.is_visible_in_tree():
            return control
    return null

func _test():
    for i in 30: await get_tree().process_frame
    EditorInterface.open_scene_from_path("res://example.tscn")
    for i in 15: await get_tree().process_frame
    var obj=EditorInterface.get_edited_scene_root().get_node("Network/Sync")
    await _select(obj)
    var panel = _visible_panel()
    if not panel or EditorInterface.get_inspector().is_ancestor_of(panel): _fail("Bottom panel missing"); return
    if panel.get_child(0).text != "添加同步属性…" or not panel.get_child(0).is_visible_in_tree(): _fail("Add button missing"); return
    for path in [^":score",^"Light:visible",^":stats:points"]:
        panel.get_child(0).pressed.emit()
        await get_tree().process_frame
        var d=panel.get_children().back()
        var item=d.nodes.get_root()
        if path.get_name_count(): item=item.get_first_child()
        item.select(0)
        d.filter.text=str(path.get_concatenated_subnames())
        d.filter.text_changed.emit(d.filter.text)
        var index=-1
        for i in d.fields.item_count:
            if d.fields.get_item_metadata(i)==path: index=i
        if index<0: _fail("Selectable property missing "+str(path)); return
        d.fields.select(index)
        d.fields.item_selected.emit(index)
        if d.get_ok_button().disabled: _fail("Cannot confirm selection"); return
        d.confirmed.emit()
        for i in 3: await get_tree().process_frame
    if obj.properties!=[^":score",^"Light:visible",^":stats:points"]: _fail("Wrong stored paths"); return
    await _select(EditorInterface.get_edited_scene_root().get_node("Light"))
    if _visible_panel(): _fail("Stale panel on ordinary node"); return
    await _select(obj)
    panel = _visible_panel()
    if not panel or panel.replica != obj: _fail("Reselection did not open the panel"); return
    var labels = []
    for label in panel.rows.find_children("*", "Label", false, false): labels.append(label.text)
    for path in obj.properties:
        if str(path) not in labels: _fail("Missing displayed path " + str(path)); return
    var check=panel.rows.find_children("*","CheckBox",true,false)[0]
    check.button_pressed=true
    if obj.client_writable!=[^":score"]: _fail("writer toggle"); return
    var manager=EditorInterface.get_editor_undo_redo()
    var hist=manager.get_history_undo_redo(manager.get_object_history_id(obj))
    hist.undo()
    if not obj.client_writable.is_empty(): _fail("undo"); return
    hist.redo()
    if obj.client_writable!=[^":score"]: _fail("redo"); return
    var packed := PackedScene.new()
    if packed.pack(EditorInterface.get_edited_scene_root()) != OK or ResourceSaver.save(packed, "res://saved.tscn") != OK: _fail("save fields"); return
    var again=load("res://saved.tscn").instantiate()
    if again.get_node("Network/Sync").client_writable!=[^":score"]: _fail("saved state"); return
    again.free()
    print("picker_pass bottom_panel=1 reselect=1 root=:score child=Light:visible writable=:score undo=1 redo=1")
    get_tree().quit()
