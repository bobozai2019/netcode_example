extends RefCounted

const CAPACITY := 8
const WIN_SCORE := 30
const RESPAWN_SECONDS := 3.0
const RESULTS_SECONDS := 6.0
const DEFAULT_PORT := 42520
const HEALTH := 100
const MAGAZINE := 30
const START_RESERVE := 90
const MAX_RESERVE := 150
const MAX_GRENADES := 2
const RELOAD_SECONDS := 1.75
const SHOT_INTERVAL := 0.12
const RIFLE_MUZZLE := Vector3(-1.04, 0.244, 0.0)
const SHOT_DAMAGE := 25
const CRATE_HEALTH := 75
const THROW_SECONDS := 0.7
const THROW_RELEASE := 0.29
const GRENADE_FUSE := 2.3
const BLAST_RADIUS := 4.0
const PICKUP_RANGE := 2.2
const PICKUP_SECONDS := 12.0
const INPUT_TIMEOUT := 0.35
const TEAL := Color("#45d9cc")
const AMBER := Color("#ffc165")
const TEAM_NAMES := ["TIDE", "EMBER"]

enum Phase { PLAY, RESULTS }
enum Pose { IDLE, RUN, CROUCH, CLIMB }
enum Action { IDLE, FIRE, RELOAD, THROW, DOWN }
enum Request { FIRE_START, FIRE_STOP, RELOAD, THROW, PICKUP }
enum Result { ACCEPTED, STALE, EMPTY, BUSY, UNAVAILABLE }
enum Pickup { AMMO, GRENADE }
enum Buttons { CROUCH = 1, JUMP = 2, FIRE = 4 }

static func team_color(team: int) -> Color:
    return TEAL if team == 0 else AMBER
