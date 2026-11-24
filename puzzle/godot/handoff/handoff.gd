extends Node2D

var game := NetcodeGame.new()
var checkpoint := 0
var announced := false
var ack_sent := false
var ack_received := false
var departing := false
var replacement := 0
var announced_player := 0

func _ready() -> void:
    var args := OS.get_cmdline_user_args()
    var port := int(args[args.find("--port") + 1])
    var host := "--puzzle-host" in args
    var err := game.open(FileAccess.get_file_as_string("res://plates.cfg"), host, "127.0.0.1", port, 3, false)
    if err != "" or not game.model(1, PackedInt32Array([1]), 0, 0) or not game.register_rpc(44, 0, true, 1, false, true):
        fail("setup " + err)
        return
    for player in [2, 3]:
        if not game.add_standby(player, "127.0.0.1", port + player - 1):
            fail("standby")
            return
    print("handoff_open")

func fail(message: String) -> void:
    push_error(message)
    set_process(false)
    get_tree().quit(1)

func _process(_delta: float) -> void:
    var f := game.advance()
    if departing and game.migration_phase() == 3:
        print("handoff_retired")
        get_tree().quit()
        return
    if f.is_empty(): return
    if f.player and f.player != announced_player:
        announced_player = f.player
        print("handoff_member player=", f.player)
    for event in f.events:
        if event.kind == 12: replacement = event.epoch
    for rpc in f.rpcs:
        if rpc.method == 44 and rpc.sender == 3 and rpc.data == PackedByteArray([88]):
            ack_received = true
    if f.host and not f.round and f.seats == 3 and game.start():
        if game.spawn(1, [77, "vault", 7], 0, 0, 0) != 1: fail("spawn")
    var fields := game.read_fields(1, false)
    if fields.size() != 3 or fields[1] != "vault" or fields[2] != 7: return
    var value: int = fields[0]
    if f.term == 1 and value == 77 and not announced:
        if f.player == 2 and f.armed and f.saved_tick:
            if not checkpoint: checkpoint = f.saved_tick
            if f.saved_tick > checkpoint:
                announced = true
                print("standby_current tick=", f.saved_tick)
        elif f.player == 3:
            announced = true
            print("first_value=77")
    if f.term != replacement: return
    if f.term == 2 and f.player == 2 and f.host:
        if value == 77 and game.submit(1, [88, "vault", 7]): print("restored=77 written=88")
        if ack_received and value == 88 and not game.submit(1, [89, "vault", 7]): fail("final write")
        if ack_received and game.read_fields(1, false)[0] == 89 and not departing:
            departing = game.handoff()
    elif f.term == 2 and f.player == 3 and value == 88 and not ack_sent:
        ack_sent = game.invoke_rpc(0, 44, PackedByteArray([88]), 0, 1)
        if ack_sent: print("resumed_rpc=88")
    elif f.term == 3 and f.player == 3 and f.host and value == 89:
        if not game.submit(1, [90, "vault", 7]) or game.read_fields(1, false)[0] != 90:
            fail("last write")
            return
        print("restored=89 written=90")
        set_process(false)
        get_tree().quit()
