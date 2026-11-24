extends Node2D

var game := NetcodeGame.new()
var adapter = preload("res://addons/netcode/forecast_body.gd").new()
@onready var body: RigidBody2D = $Body
var hosting := false
var contact := false
var slept := false
var woke := false
var reported := false
var phase := 0
var generation := 0
var logged := -1
var trajectory_sample := 0
var revision := 0
var deadline := 0.0

func _ready() -> void:
    var args := OS.get_cmdline_user_args()
    hosting = "--puzzle-host" in args
    var i := args.find("--port")
    var port := int(args[i+1]) if i >= 0 else 43475
    var address_index := args.find("--address")
    var address := args[address_index+1] if address_index >= 0 else "127.0.0.1"
    var err := game.open(FileAccess.get_file_as_string("res://body.cfg"),hosting,address,port,5,false)
    if err != "":
        push_error(err)
        get_tree().quit(1)
        return
    print("forecast_open engine=godot")

func _on_body_entered(_other: Node) -> void:
    contact = true

func _physics_process(_dt: float) -> void:
    var f := game.advance()
    if f.is_empty(): return
    if hosting and not f.round and f.seats >= 3 and game.start():
        body.linear_velocity=Vector2(150,0)
        game.spawn(1,adapter.sample(body,0,0),0,0,0)
    if not f.round: return
    if hosting:
        if phase==0 and contact:
            phase=1
            deadline=f.time+.8
        elif phase==1 and f.time>=deadline:
            body.linear_velocity=Vector2.ZERO
            body.sleeping=true
            phase=2
            deadline=f.time+.6
        elif phase==2 and f.time>=deadline:
            body.sleeping=false
            body.global_position=Vector2(400,0)
            body.linear_velocity=Vector2(25,0)
            generation+=1
            phase=3
            deadline=f.time+.7
        elif phase==3 and f.time>=deadline:
            body.linear_velocity=Vector2.ZERO
            body.sleeping=true
            phase=4
        game.submit(1,adapter.sample(body,generation,phase))
    else:
        var fields := game.read_fields(1,false)
        if fields.is_empty(): return
        var rev := game.revision(1)
        if rev!=revision:
            adapter.mode = adapter.Correction.BLEND if fields[6] < 2 else adapter.Correction.FORCE
            adapter.max_forecast = 0.25
            adapter.apply(body,fields,f.time-game.sample_time(1))
            revision=rev
        phase=fields[6]
    var x := body.global_position.x/50
    if trajectory_sample < 4 and f.time >= 0.35 + trajectory_sample * 0.15:
        print("forecast_point index=",trajectory_sample," x_mm=",int(x*1000))
        trajectory_sample += 1
    if logged!=phase:
        print("forecast_stage phase=",phase," x=",x," sleep=",body.sleeping," contact=",contact)
        logged=phase
    if phase==2 and body.sleeping: slept=true
    if phase==3 and x>=7.8 and not body.sleeping and body.linear_velocity.x>0: woke=true
    if not reported and phase==4 and contact and slept and woke and body.sleeping and x>8:
        reported=true
        print("forecast_pass engine=godot contact=1 slept=1 woke=1 final_mm=",int(x*1000))
