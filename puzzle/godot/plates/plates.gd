extends Node2D

var game := NetcodeGame.new()
var hosting := false
var automatic := false
var map_asset: PackedScene
var fetching_map := false
var pending_maps := {}
var mounted_maps := {}
var map_phase := 0
var move_requested := false
var claimed := false
var submitted := false
var command_sent := false
var input_sent := false
var charge_reported := false
var ack_reported := false
var solved := false
var clock_reported := false
var deadline_ms := 0
var cells := [0, 0]
var labels := ["Amber", "Jade"]

func _ready() -> void:
    var args := OS.get_cmdline_user_args()
    hosting = "--puzzle-host" in args
    automatic = "--puzzle-auto" in args
    var index := args.find("--port")
    var port := int(args[index + 1]) if index != -1 else 43271
    index = args.find("--address")
    var address := args[index + 1] if index != -1 else "127.0.0.1"
    var err := game.open(FileAccess.get_file_as_string("res://plates.cfg"), hosting, address, port, 5, false)
    if err != "" or not game.model(1, PackedInt32Array([1]), 0, 0) or not game.register_rpc(31, 0, true, 1, true, false):
        push_error(err if err != "" else "Plate model registration failed")
        get_tree().quit(1)
        return
    if not game.register_prediction(2, 1, PackedByteArray([0]), _charge_step):
        get_tree().quit(1)
        return
    if hosting: game.set_player_ttl(15000)
    print("puzzle_open engine=godot host=", int(hosting))

func _charge_step(fields: Array, input: PackedByteArray, _tick: int) -> Array:
    return [fields[0] + input[0]]

func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed("ui_accept"):
        move_requested = true

func _map_event(event: Dictionary) -> void:
    var scene: int = event.object
    if event.kind == 9:
        if pending_maps.erase(scene):
            print("map_cancel scene=", scene, " generation=", event.epoch)
        if mounted_maps.has(scene):
            var node: Node = mounted_maps[scene]
            remove_child(node)
            node.queue_free()
            mounted_maps.erase(scene)
            print("map_removed scene=", scene, " generation=", event.epoch)
    elif event.kind == 8 and game.map_asset(scene) == "plates":
        pending_maps[scene] = event.epoch
        if not map_asset and not fetching_map:
            fetching_map = ResourceLoader.load_threaded_request("res://verification/plates/plate_room.tscn") == OK
            if not fetching_map: push_error("Could not request plate room")

func _mount_maps() -> void:
    if fetching_map:
        var status := ResourceLoader.load_threaded_get_status("res://verification/plates/plate_room.tscn")
        if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS: return
        fetching_map = false
        if status == ResourceLoader.THREAD_LOAD_LOADED:
            map_asset = ResourceLoader.load_threaded_get("res://verification/plates/plate_room.tscn")
        else: push_error("Could not load plate room")
    if pending_maps.is_empty() and mounted_maps.is_empty(): map_asset = null
    if not map_asset: return
    for scene in pending_maps.keys():
        var generation: int = pending_maps[scene]
        if automatic and scene == 2 and generation == 2: continue
        var node := map_asset.instantiate()
        add_child(node)
        if not node.has_node("PlateAnchor"): get_tree().quit(1); return
        mounted_maps[scene] = node
        pending_maps.erase(scene)
        if not hosting: game.loaded(scene, generation)
        print("map_mounted scene=", scene, " generation=", generation, " anchors=1")

func _process(_dt: float) -> void:
    var frame := game.advance()
    if frame.is_empty(): return
    var player: int = frame.player
    for result in frame.rpc_outcomes:
        if result.method == 31 and result.status == 0: print("plate_ack token=",result.token," player=",result.player)
    for call in frame.rpcs:
        if call.method == 31 and call.data.size() == 1:
            print("plate_action player=", call.sender, " object=", call.object, " value=", call.data[0])
    for event in frame.events:
        if event.kind in [8, 9]: _map_event(event)
        if event.kind == 11 and event.object == 3 and event.sequence == 1 and not ack_reported:
            ack_reported = true
            print("charge_ack sequence=1")
        if event.kind == 5: game.answer(event, true)
        elif event.kind == 6 and event.status != 0: claimed = false
    _mount_maps()
    if hosting and frame.round == 0 and frame.seats >= 3 and game.start():
        game.load_map(1, "plates")
        game.spawn(1, [0, "Amber", 3200], 1, 100, 0)
        game.spawn(1, [0, "Jade", 3200], 1, 200, 0, 1)
        var meter := game.spawn(2, [0], 1, 300, 0)
        game.distribute(meter, 1, PackedInt64Array([81]), 1)
        for member in [2, 3]: game.subscribe(member, 1, PackedInt64Array([81]), PackedInt32Array([1]))
        game.bind_prediction(meter, 2)
    if hosting and automatic and frame.round:
        if map_phase == 0 and frame.time > 0.45:
            game.load_map(2, "plates")
            map_phase = 1
        elif map_phase == 1 and frame.time > 1.25:
            game.unload_map(2)
            game.load_map(2, "plates")
            map_phase = 2
        elif map_phase == 2 and frame.time > 2.4:
            game.unload_map(2)
            map_phase = 3
    if player == 2 and not input_sent and automatic and game.predict(3, PackedByteArray([5])):
        input_sent = true
        if game.predicted_fields(3) == [5]: print("charge_predicted value=5")
    if not charge_reported and game.read_fields(3, false) == [5]:
        charge_reported = true
        print("charge_confirmed value=5")
    for i in range(2):
        var values := game.read_fields(game.find_object(1, (i + 1) * 100), false)
        if values.size() == 3:
            deadline_ms = values[2]
            cells[i] = values[0]
            labels[i] = values[1]
    if (automatic or move_requested) and player in [2, 3]:
        var id := player - 1
        if game.writer(id) != player:
            if not claimed: claimed = game.claim(id)
        elif not submitted:
            submitted = game.submit(id, [3 if id == 1 else 7])
        if submitted and not command_sent:
            command_sent = game.invoke_rpc(id, 31, PackedByteArray([3 if id == 1 else 7]), 0, id)
    if not solved and cells == [3, 7] and labels == ["Amber", "Jade"] and game.writer(1) == 2 and game.writer(2) == 3:
        solved = true
        print("puzzle_solved engine=godot player=",player," first=",game.writer(1)," second=",game.writer(2))
    if not clock_reported and deadline_ms and frame.time * 1000 >= deadline_ms:
        clock_reported = true
        print("countdown_reached deadline_ms=",deadline_ms," observed_ms=",int(frame.time*1000))
    queue_redraw()

func _draw() -> void:
    var font := ThemeDB.fallback_font
    draw_string(font, Vector2(36, 65), "Pressure plates", HORIZONTAL_ALIGNMENT_LEFT, -1, 34)
    for i in range(2):
        var y := 136.0 + i * 74
        draw_string(font, Vector2(38, y + 24), labels[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 22)
        for j in range(8):
            var cell := Rect2(146 + j * 54, y, 46, 34)
            draw_rect(cell, Color("#353e49"))
            if j == [3,7][i]: draw_rect(cell, Color.WHITE, false, 2)
            if cells[i] == j: draw_rect(cell.grow(-5), [Color.CORAL, Color.AQUAMARINE][i])
    var hint := "Both plates aligned" if solved else ("Waiting for both players" if hosting else "Space to move your plate")
    draw_string(font, Vector2(38, 325), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 20)
