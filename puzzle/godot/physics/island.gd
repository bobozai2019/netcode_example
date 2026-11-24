extends Node3D

const Island = preload("res://addons/netcode/physics_island_3d.gd")
const ISLAND_WORLD := preload("res://verification/physics/island_world.tscn")
var game := NetcodeGame.new()
var host := false
var busy := false
var allow_reset := false

func _ready() -> void:
    var args := OS.get_cmdline_user_args()
    host = "--puzzle-host" in args
    allow_reset = "--authority-reset" in args
    var port := int(args[args.find("--port")+1])
    if game.open(FileAccess.get_file_as_string("res://island.cfg"),host,"127.0.0.1",port,2,false)!="" or not game.register_rpc(45,0,true,1,false,true):
        fail("setup")
        return
    print("island_open")

func fail(message: String) -> void:
    push_error(message)
    set_process(false)
    get_tree().quit(1)

func group() -> Array:
    var viewport := ISLAND_WORLD.instantiate() as SubViewport
    add_child(viewport)
    var island := Island.new()
    for i in 4:
        island.add(i+1, viewport.get_node("Body%d" % i))
    return [viewport,island]

func step_input(g: Array,tick: int,disturb: bool) -> void:
    var b: Dictionary=g[1].bodies
    if tick==41: b[4].apply_impulse(Vector3.UP*2,Vector3.RIGHT*.35)
    if tick!=48: return
    b[2].apply_central_impulse(Vector3(.8,1.4,.3))
    b[4].apply_impulse(Vector3.UP*2,Vector3.RIGHT*.4)
    if disturb: b[1].apply_central_impulse(Vector3.LEFT*3)

func pos(p: PackedFloat32Array,i:int) -> Vector3:
    return Vector3(p[i*13],p[i*13+1],p[i*13+2])

func error(a: Array,b: Array) -> float:
    var maximum := 0.0
    for i in 4: maximum=maxf(maximum,pos(a[3],i).distance_to(pos(b[3],i)))
    return maximum

func produce() -> void:
    await get_tree().physics_frame
    var g := group()
    var checkpoint: Array
    for tick in range(1,71):
        step_input(g,tick,false)
        await get_tree().physics_frame
        if tick==45: checkpoint=g[1].capture(tick)
    if game.spawn(1,checkpoint,0,0,0)!=1 or game.spawn(1,g[1].capture(70),0,0,0)!=2: fail("spawn")
    g[0].queue_free()

func replay(checkpoint: Array,live: Array) -> void:
    await get_tree().physics_frame
    var predicted := group()
    for tick in range(1,71):
        step_input(predicted,tick,true)
        await get_tree().physics_frame
    var before := error(live,predicted[1].capture(70))
    predicted[0].queue_free()
    var corrected := group()
    var reference := group()
    if corrected[1].restore([45,PackedInt32Array(),PackedInt32Array(),PackedFloat32Array()]) or not corrected[1].restore(checkpoint) or not reference[1].restore(checkpoint):
        fail("invalid checkpoint")
        return
    for tick in range(46,71):
        step_input(corrected,tick,false)
        step_input(reference,tick,false)
        await get_tree().physics_frame
    var end: Array=corrected[1].capture(70)
    var after := error(live,end)
    var cold := error(end,reference[1].capture(70))
    var gap := absf(pos(end[3],2).distance_to(pos(end[3],3))-1)
    var speed := Vector3(checkpoint[3][46],checkpoint[3][47],checkpoint[3][48]).length()
    var reset := allow_reset and after>=.06
    if reset and not corrected[1].restore(live):
        fail("could not restore latest authoritative group")
        return
    var final := error(live,corrected[1].capture(70)) if reset else after
    if not (speed>.1 and checkpoint[0]==45 and live[0]==70 and pos(checkpoint[3],1).y-pos(checkpoint[3],0).y>.95 and before>.1 and final<(.001 if reset else .06) and cold<.001 and gap<.025):
        fail("replay error before=%f after=%f cold=%f joint=%f"%[before,after,cold,gap])
        return
    print("island_pass bodies=4 checkpoint=45 steps=25 before_mm=%.2f after_mm=%.2f cold_mm=%.2f joint_mm=%.2f reset=%d final_mm=%.2f"%[before*1000,after*1000,cold*1000,gap*1000,int(reset),final*1000])
    if not game.invoke_rpc(0,45,PackedByteArray([70]),0,1):
        fail("confirmation")
        return
    await get_tree().create_timer(1).timeout
    get_tree().quit()

func _process(_dt: float) -> void:
    var f:=game.advance()
    if f.is_empty(): return
    for rpc in f.rpcs:
        if host and rpc.sender==2 and rpc.method==45 and rpc.data==PackedByteArray([70]):
            print("island_confirmed")
            set_process(false)
            get_tree().quit()
            return
    if busy: return
    if host and f.seats==2 and game.start():
        busy=true
        produce()
    elif not host:
        var cp:=game.read_fields(1,false)
        var live:=game.read_fields(2,false)
        if cp.size()==4 and live.size()==4:
            busy=true
            replay(cp,live)
