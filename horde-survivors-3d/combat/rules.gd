
extends RefCounted

enum Weapon { KNIFE, HALO, LIGHTNING }
enum Result { LIVE, VICTORY, DOWN, TIMEOUT }
enum Gameplay { SURVIVAL, STRESS_TEST }
const HZ := 60
const DEADLINE := 360 * HZ
const SURVIVAL_ENEMY_LIMIT := 128
const STRESS_ENEMY_LIMIT := 1024
const MOVE_SPEED := 6.8
const PLAYER_RADIUS := 0.34

static func damage(weapon: int) -> int:
	return [12, 18, 25][weapon]

static func radius(level: int) -> float:
	return 2.5 + 0.65 * level

static func threshold(level: int) -> int:
	return 8 + level * 5

static func xz(point: Vector2, height := 0.0) -> Vector3:
	return Vector3(point.x, height, point.y)
