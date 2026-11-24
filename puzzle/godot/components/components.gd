extends Node2D

var score := 0
var weights := Vector4.ZERO
var tint := Color.BLACK
var selected := 0
var badge := PackedByteArray()
var route := PackedVector2Array()
var scores: Dictionary[int,int] = {}
var queue: Array[int] = []
var game := NetcodeGame.new()
@onready var panel: NetcodeReplicatedObject = $Panel
@onready var motion: NetcodeReplicatedObject = $Body2D/Motion
@onready var body: RigidBody2D = $Body2D
@onready var body3: RigidBody3D = $Body3D
@onready var motion3: NetcodeReplicatedObject = $Body3D/Motion
var host := false
var seeded := false
var next_claim := 0
var claimed := false
var reported := false
var received := false
var finishing := false

func _ready() -> void:
    var args := OS.get_cmdline_user_args()
    host = "--puzzle-host" in args
    var port := int(args[args.find("--port")+1])
    if game.open(FileAccess.get_file_as_string("res://components.cfg"),host,"127.0.0.1",port,2,false)!="" or not game.model(1,PackedInt32Array([1]),0,0):
        fail("setup"); return
    if not game.bind_method("Report",71,2,0,true,true,false,_report) or not game.bind_method("Done",72,0,1,true,false,true,_done):
        fail("method registration"); return
    if not panel.bind(game,1) or not motion.bind(game,2) or not motion3.bind(game,3): fail("component binding"); return
    print("sdk_build_id=", NetcodeGame.sdk_build_id())
    print("components_open")

func fail(text: String) -> void:
    push_error(text)
    set_process(false)
    get_tree().quit(1)

func _report(sender: int, object: int, total: int, label: String, spot: Vector2) -> void:
    if not host or sender!=2 or object!=1 or total!=42 or label!="ready" or spot!=Vector2(2,-3) or received:
        fail("unexpected typed report"); return
    received=true

func _done(sender: int, object: int) -> void:
    if host or sender!=1 or object!=0 or not reported: fail("unexpected reply"); return
    print("components_pass role=guest score=42 fields=8 body=1 reference=1 typed=1 body3d=1")
    get_tree().quit()

func _process(_dt: float) -> void:
    var f:=game.advance()
    if f.is_empty(): return
    for e in f.events:
        if e.kind==5: game.answer(e,true)
        if not host and e.kind==6 and e.object==1 and e.status!=0:
            if e.status!=4: fail("claim rejected, status %d" % e.status); return
            claimed=false
            next_claim=Time.get_ticks_msec()+250
    if host and not f.round and f.seats==2 and game.start():
        if game.spawn(1,[0,weights,tint,selected,badge,route,scores,queue],0,0,0)!=1 or game.spawn(3,[Vector2.ZERO,0.0,Vector2.ZERO,0.0,false,0,0],0,0,0)!=2 or game.spawn(4,[Vector3.ZERO,Quaternion.IDENTITY,Vector3.ZERO,Vector3.ZERO,false,0,0],0,0,0)!=3:
            fail("spawn"); return
    if not panel.initialized or not motion.initialized or not motion3.initialized: return
    if host:
        if not seeded:
            weights=Vector4(2,3,4,5); tint=Color(.25,.5,.75,1); selected=motion.reference()
            badge=PackedByteArray([0,255,7]); route=PackedVector2Array([Vector2(2,-3)])
            scores={-3:16777219,4:42}; queue.assign([5,5,-1])
            body3.position=Vector3(0,0,3); motion3.teleport_generation+=1
            score=7; body.position.x=200; motion.teleport_generation+=1; seeded=true
        if received and score==42 and not finishing:
            if not game.call_method("Done",0,[],2): fail("reply"); return
            finishing=true
            print("components_pass role=host score=42 fields=8 body=1 reference=1 typed=1 body3d=1")
            await get_tree().create_timer(1).timeout
            get_tree().quit()
    else:
        if not claimed and Time.get_ticks_msec()>=next_claim and score==7 and weights==Vector4(2,3,4,5) and tint==Color(.25,.5,.75,1) and panel.resolve_node(selected)==body and badge==PackedByteArray([0,255,7]) and route==PackedVector2Array([Vector2(2,-3)]) and scores=={-3:16777219,4:42} and queue==[5,5,-1] and absf(body.position.x-200)<1 and absf(body3.position.z-3)<0.02:
            if game.call_method("Report",1,[42,"ready",Vector2(2,-3)]): fail("writer gate"); return
            claimed=game.claim(1)
        if claimed and game.writer(1)==2:
            score=42
            var confirmed:=game.read_fields(1,false)
            if confirmed.size() and confirmed[0]==42 and not reported:
                if game.call_method("Report",1,[42,"X".repeat(17),Vector2.ZERO]) or game.call_method("Report",1,["wrong"]): fail("argument gate"); return
                reported=game.call_method("Report",1,[42,"ready",Vector2(2,-3)])
