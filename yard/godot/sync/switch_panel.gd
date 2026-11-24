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

@rpc("any_peer","call_local","reliable")
func pulse(sequence:int) -> void:
	local_calls.append([session.get_rpc_sender(),sequence])

@rpc("any_peer","call_remote","unreliable")
func ping(sequence:int) -> void:
	directed.append([session.get_rpc_sender(),sequence])
