extends Node

var room := preload("res://addons/netcode/scene_room.gd").new()
@onready var left = $Left
@onready var right = $Right
@onready var replicas = [$Left/Sync,$Right/Sync,$Body/Sync,$Character/Sync]
var player := 0
const PAYLOAD := {"wave":[4294967301,"go"]}
var late_ready:=false
var typed_ok:=false
var collection_ok:=false
var seeded:=false
var pending:=false
var tested_mask:=false
var tested_rigid:=false
var next_claim:=0
var reported:=false
var directed_sent:=false
var directed_ack:=false
var replies:Dictionary={}
var done:=false
var finishing:=false
var opened:=Time.get_ticks_msec()

func fail(message:String) -> void:
    push_error(message)
    set_process(false)
    get_tree().quit(1)

func _ready() -> void:
    var args:=OS.get_cmdline_user_args()
    left.session=room
    right.session=room
    room.register_broadcast_receiver(self)
    var error:=room.open(self,"--host" in args,"127.0.0.1",int(args[args.find("--port")+1]),3)
    if not error.is_empty(): fail(error); return
    print("scene_open")

@rpc("any_peer","call_remote","reliable")
func acknowledge(sequence:int) -> void:
    var sender:=room.get_rpc_sender()
    if sequence==7 and player==1 and sender==3: late_ready=true
    elif sequence==9 and sender==3 and player==2: directed_ack=true
    elif sequence==10 and player==1 and sender in [2,3]: replies[sender]=true
    else: fail("unexpected room receiver or sender")

@rpc("any_peer","call_remote","reliable")
func receive_collection(payload:Dictionary) -> void:
    var info:=room.get_rpc_info()
    if payload!=PAYLOAD or player!=3 or info.sender!=2 or info.target!=3 or info.target_node!=null:
        fail("collection or RPC context"); return
    collection_ok=true

@rpc("any_peer","call_remote","reliable")
func receive_palette(colors:Array[Color]) -> void:
    if colors!=[Color.RED] or room.get_rpc_sender()!=2 or player!=3: fail("typed collection"); return
    typed_ok=true

@rpc
func finished() -> void:
    if room.get_rpc_sender()!=1 or player==1: fail("invalid finish"); return
    done=true

func _process(_dt:float) -> void:
    if Time.get_ticks_msec()-opened>30000: fail("timeout player=%d score=%d pending=%s reports=%s pulse=%s directed=%s replies=%s"%
        [player,left.score,pending,left.reports,right.local_calls,left.directed,replies]); return
    var frame:=room.advance()
    if frame.is_empty(): return
    player=frame.player
    for event in frame.events:
        if event.kind==5: room.game.answer(event,true)
        if event.kind==6 and event.status==4:
            pending=false
            next_claim=Time.get_ticks_msec()+250
    if frame.host and not frame.round and frame.seats==2 and room.game.start():
        for replica in replicas:
            if not room.spawn(replica): fail("spawn"); return
    for replica in replicas:
        if not replica.initialized: return
    if frame.host and not seeded:
        left.score=7
        left.stats.points=4294967303
        var entry=left.Stats.new()
        entry.points=51
        entry.tint=Color.BLUE
        left.squad.append(entry)
        left.selected=right
        left.marks.assign([4,4,-1])
        left.palette.assign([Color.RED,Color.BLUE])
        $Left/Light.visible=false
        $Body.position.z=3
        $Body.collision_layer=5
        $Character.velocity=Vector2(4,5)
        left.position=Vector2(8,2)
        seeded=true
        print("scene_seeded")
    if player==2 and not pending and left.score==7 and _state_ok() and Time.get_ticks_msec()>=next_claim:
        room.unregister_broadcast_receiver(self)
        if room.rpc_to(room.TARGET_MASTER,acknowledge,10) or not room.register_broadcast_receiver(self): fail("receiver lifecycle"); return
        if room.rpc(finished) or room.rpc_to(room.TARGET_OWNER,acknowledge,10) or room.rpc(fail,"invalid"): fail("invalid call accepted"); return
        if room.rpc_to(room.TARGET_MASTER,left.report,7,"early",Vector2.ZERO,right): fail("writer gate"); return
        pending=room.game.claim(replicas[0].object_id)
    if player==2 and pending and replicas[0].has_authority():
        left.score=42
        if not tested_mask:
            $Left/Light.visible=true
            tested_mask=true
        if not reported and frame.seats==3:
            if room.rpc_to(room.TARGET_MASTER,left.report,"bad","label",Vector2.ZERO,right): fail("type gate"); return
            reported=room.rpc_to(room.TARGET_MASTER,left.report,42,"ready",Vector2(2,-3),right)
    if player==3 and not tested_rigid and _state_ok():
        $Body.collision_layer=12
        tested_rigid=true
    if player==3 and tested_rigid and not late_ready and _state_ok():
        late_ready=room.rpc_to(room.TARGET_MASTER,acknowledge,7)
    if frame.host and late_ready and left.score==42 and left.reports.size()==1 and not directed_sent and 3 in room.game.routing_info(replicas[1].object_id).audience:
        if left.reports[0]!=[2,42,"ready",Vector2(2,-3),right] or not right.reports.is_empty(): fail("wrong instance or arguments"); return
        if room.rpc(right.pulse,8,9) or room.rpc(right.pulse,"bad"): fail("invalid optional arguments"); return
        if not room.rpc(right.pulse) or right.local_calls!=[[1,8]]: fail("optional argument or immediate call_local"); return
        if room.get_rpc_info()!=null or room.get_rpc_sender()!=0: fail("stale RPC context"); return
        directed_sent=true
    if player==3 and right.local_calls==[[1,8]] and not directed_sent and _state_ok() and room.game.routing_info(replicas[0].object_id,false).writer==2:
        directed_sent=room.rpc_to(room.TARGET_OWNER,left.ping,9)
    if player==2 and reported and left.directed==[[3,9]] and not directed_sent:
        if room.rpc_to_player(3,receive_collection,{"resource":Resource.new()}): fail("unsupported collection"); return
        if room.rpc_to_player(3,receive_palette,[1]): fail("collection type gate"); return
        if not room.rpc_to_player(3,receive_palette,[Color.RED]): fail("typed collection enqueue"); return
        if not room.rpc_to_player(3,receive_collection,PAYLOAD): fail("collection enqueue"); return
        directed_sent=room.rpc_to_player(3,left.ping,11)
    if player==3 and typed_ok and collection_ok and left.directed==[[2,11]] and not reported:
        reported=room.rpc_to_player(2,acknowledge,9)
        if reported: room.rpc_to(room.TARGET_MASTER,acknowledge,10)
    if player==2 and directed_ack and not replies.has(2):
        replies[2]=room.rpc_to(room.TARGET_MASTER,acknowledge,10)
    if frame.host and replies.size()==2 and not finishing:
        if not left.directed.is_empty() or not room.rpc(finished): fail("routing"); return
        finishing=true
        await get_tree().create_timer(0.4).timeout
        done=true
    if done:
        if not left.local_calls.is_empty() or not _state_ok(): fail("final fields or destination"); return
        print("scene_pass player=%d score=%d"%[player,left.score])
        set_process(false)
        get_tree().quit()

func _state_ok() -> bool:
    return (
        left.squad.size()==1 and left.squad[0].points==51 and left.squad[0].tint==Color.BLUE
        and left.stats.points==4294967303 and left.selected==right
        and left.palette==[Color.RED,Color.BLUE] and left.marks==[4,4,-1]
        and not $Left/Light.visible and $Body.collision_layer==5
        and absf($Body.position.z-3)<0.02
        and $Character.velocity.distance_to(Vector2(4,5))<0.1
        and left.position.distance_to(Vector2(8,2))<0.1
    )

func _exit_tree() -> void:
    room.unregister_broadcast_receiver(self)
    room.close()
