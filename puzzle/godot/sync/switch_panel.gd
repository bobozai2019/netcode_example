extends Node2D

const Stats = preload("res://sync/panel_stats.gd")
var stats:=Stats.new()
var squad:Array[Stats]=[]
var score := 0
var palette: Array[Color] = []
var selected: Node
var marks: Array[int] = []
var session
var reports:Array=[]
var local_calls:Array=[]
var directed:Array=[]

@rpc("authority","call_remote","reliable")
func report(total:int,label:String,spot:Vector2,source:Node) -> void:
    reports.append([session.get_rpc_sender(),total,label,spot,source])

@rpc("any_peer","call_local")
func pulse(sequence:int=8) -> void:
    var info=session.get_rpc_info()
    assert(info.sender==session.get_rpc_sender() and info.target==session.TARGET_ALL and info.target_node==self)
    local_calls.append([info.sender,sequence])

@rpc("any_peer","call_remote","unreliable")
func ping(sequence:int) -> void:
    var info=session.get_rpc_info()
    var expected_target:int=session.TARGET_OWNER if sequence==9 else 3
    assert(info.target==expected_target and info.target_node==self)
    directed.append([info.sender,sequence])
