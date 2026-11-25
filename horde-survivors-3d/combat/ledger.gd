
extends RefCounted

const Rules = preload("res://combat/rules.gd")

enum HitResult { APPLIED, DUPLICATE, DEAD, INVALID }
var enemies: Dictionary[int, Dictionary] = {}
var hits: Dictionary[Vector4i, Vector3i] = {}
var deaths: Dictionary[int, Vector2] = {}
var stones: Dictionary[int, Dictionary] = {}
var experience := 0
var unspent_experience := 0
var level := 0
var xp_version := 0
var alive_count := 0
var applied_count := 0
var duplicates := 0
var choices: Dictionary[Vector2i, int] = {}

func add_enemy(id: int, hp: int, owner: int) -> void:
	enemies[id] = {"hp": hp, "version": 0, "generation": 1, "owner": owner}
	alive_count += 1

func evaluate(key: Vector4i, damage: int) -> Vector3i:
	var record: Dictionary = enemies.get(key.z, {})
	if hits.has(key):
		var prior := hits[key]
		return Vector3i(HitResult.DUPLICATE, prior.y, prior.z)
	if record.is_empty():
		return Vector3i(HitResult.INVALID, 0, 0)
	if int(record.hp) <= 0:
		return Vector3i(HitResult.DEAD, 0, int(record.version))
	return Vector3i(HitResult.APPLIED, maxi(0, int(record.hp) - damage), int(record.version) + 1)

func commit(key: Vector4i, result: Vector3i, position: Vector2, value: int) -> void:
	if result.x == HitResult.DUPLICATE:
		duplicates += 1
	if result.x != HitResult.APPLIED or hits.has(key):
		return
	var record := enemies[key.z]
	record.hp = result.y
	record.version = result.z
	hits[key] = result
	applied_count += 1
	if result.y == 0:
		alive_count -= 1
		deaths[key.z] = position
		stones[key.z] = {"position": position, "value": value, "winner": 0}

func take_stone(id: int, player: int) -> int:
	var stone: Dictionary = stones.get(id, {})
	if stone.is_empty():
		return 0
	if int(stone.winner) == 0:
		stone.winner = player
		experience += int(stone.value)
		unspent_experience += int(stone.value)
		xp_version += 1
		while unspent_experience >= Rules.threshold(level):
			unspent_experience -= Rules.threshold(level)
			level += 1
	return int(stone.winner)
