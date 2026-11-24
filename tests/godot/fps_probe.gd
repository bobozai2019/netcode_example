extends Node

const Main = preload("res://app/main.gd")
const Rules = preload("res://net/config.gd")

var folder := OS.get_environment("SHIFTLINE_PROBE")
var app: Main
var next_poll := 0
var watched_round := 0
var dead_at: Dictionary[int, float] = {}
var respawn_lateness: Dictionary[int, float] = {}

func _ready() -> void:
    process_physics_priority = 20

func _physics_process(_delta: float) -> void:
    if not app or not app.match_state or not app.match_state.is_host:
        return
    var game := app.match_state
    if watched_round != game.match_id:
        watched_round = game.match_id
        dead_at.clear()
        respawn_lateness.clear()
    for slot in game.slots:
        if not slot.active:
            continue
        if not slot.alive and slot.respawn_at > 0.0:
            dead_at[slot.player_id] = slot.respawn_at
        elif slot.alive and dead_at.has(slot.player_id):
            respawn_lateness[slot.player_id] = game.now - dead_at[slot.player_id]
            dead_at.erase(slot.player_id)

func _process(_delta: float) -> void:
    if folder.is_empty() or Time.get_ticks_msec() < next_poll:
        return
    next_poll = Time.get_ticks_msec() + 25
    app = get_tree().current_scene as Main
    var path := folder.path_join("command.json")
    if not app or not FileAccess.file_exists(path):
        return
    var raw := FileAccess.get_file_as_string(path)
    if raw.is_empty():
        return
    var parser := JSON.new()
    if parser.parse(raw) == OK and parser.data is Dictionary and DirAccess.remove_absolute(path) == OK:
        execute(parser.data)

func execute(command: Dictionary) -> void:
    var hud := app.hud
    var scene := app.match_state
    var report := {}
    match command.op:
        "open":
            hud.profile.text = command.nickname
            hud.port_input.text = str(int(command.port))
            if command.host:
                for index in hud.host_address.item_count:
                    if hud.host_address.get_item_text(index) == command.address:
                        hud.host_address.select(index)
                hud.host_button.pressed.emit()
            else:
                hud.address.text = command.address
                hud.join_button.pressed.emit()
        "cancel": hud.cancel_button.pressed.emit()
        "resume": hud.continue_requested.emit()
        "leave": hud.leave_requested.emit()
        "action":
            input_action(command.action, command.pressed)
        "tap":
            input_action(command.action, true)
            input_action(command.action, false)
        "aim":
            var direction := Vector3(command.direction[0], command.direction[1], command.direction[2]).normalized()
            var yaw := atan2(-direction.x, -direction.z)
            var pitch := asin(direction.y)
            var motion := InputEventMouseMotion.new()
            motion.relative = Vector2(wrapf(app.aim_yaw - yaw, -PI, PI), app.aim_pitch - pitch) / Main.LOOK_SENSITIVITY
            app._input(motion)
        "place":
            var slot := scene.slot_for(int(command.player))
            slot.position = Vector3(command.position[0], command.position[1], command.position[2])
            slot.velocity = Vector3.ZERO
        "set_score":
            scene.score_a = int(command.a)
            scene.score_b = int(command.b)
        "inspect_bones":
            var view := app.viewmodel
            var rig := view.skeleton
            for key in ["wrist.r", "wrist.l", "socket.r", "socket.l", "bicep.r", "bicep.l", "forearm.r", "forearm.l"]:
                var world := rig.global_transform * rig.get_bone_global_pose(rig.find_bone(key)).origin
                var point := view.to_local(world)
                report[key] = vec(point)
        "capture":
            await RenderingServer.frame_post_draw
            if command.get("require_flash", false):
                var deadline := Time.get_ticks_msec() + 1200
                while not app.viewmodel.flash.is_visible_in_tree() and Time.get_ticks_msec() < deadline:
                    await RenderingServer.frame_post_draw
                report["captured_flash"] = app.viewmodel.flash.is_visible_in_tree()
            var texture := get_viewport().get_texture()
            var capture_path := folder.get_base_dir().path_join(command.name + ".png")
            report["image"] = texture.get_image().save_png(capture_path)
        "quit":
            app.leave_room("")
            get_tree().quit()
    var result := snapshot()
    result.merge(report)
    var reply := folder.path_join("answer-%d.json" % command.id)
    var staging := reply + ".tmp"
    var file := FileAccess.open(staging, FileAccess.WRITE)
    file.store_string(JSON.stringify(result))
    file.close()
    DirAccess.rename_absolute(staging, reply)

func input_action(action: StringName, pressed: bool) -> void:
    var event := InputEventAction.new()
    event.action = action
    event.pressed = pressed
    Input.parse_input_event(event)
    Input.flush_buffered_events()

func vec(point: Vector3) -> Array:
    return [point.x, point.y, point.z]

func snapshot() -> Dictionary:
    var scene := app.match_state
    var hud := app.hud
    var info := {"lobby": hud.lobby.visible, "message": hud.status.text, "interface": hud.root.visible,
        "menu": hud.menu.visible, "roster": hud.roster.visible, "reticle": hud.crosshair.is_visible_in_tree(),
        "pending": hud.cancel_button.visible, "mouse": Input.mouse_mode, "ready": app.camera != null}
    if not scene:
        return info
    var players: Array = []
    for slot in scene.slots:
        if slot.active:
            var soldier = slot.soldier
            players.append({"id": slot.player_id, "name": slot.nickname, "team": slot.team, "kills": slot.kills,
                "deaths": slot.deaths, "life": slot.life_id, "position": vec(slot.position), "pose": slot.pose,
                "hp": slot.hp, "alive": slot.alive, "action": slot.action, "until": slot.action_until,
                "respawn_at": slot.respawn_at, "mag": slot.magazine, "reserve": slot.reserve, "grenades": slot.grenades,
                "ping": slot.ping_ms, "collider": slot.collision_layer, "avatar": soldier.visible,
                "animation": soldier.current, "animation_time": soldier.player.current_animation_position if soldier.current else 0.0,
                "rifle_visible": soldier.rifle != null and soldier.rifle.is_visible_in_tree(),
                "holding_aim": soldier.holding_aim,
                "bones": soldier.skeleton.get_bone_count()})
    var crates: Array = []
    for crate in scene.warehouse.crates:
        crates.append([crate.destroyed, crate.hp, crate.cover.collision_layer])
    var pickups: Array = []
    for pickup in scene.warehouse.pickups:
        pickups.append([pickup.kind, pickup.available, pickup.generation])
    var throws: Array = []
    for grenade in scene.grenades.values():
        throws.append([vec(grenade.position), grenade.detonate_at, grenade.thrower_id, grenade.appearance.visible])
    var view := app.viewmodel
    info.merge({"id": scene.local_player_id, "players": players, "seats": scene.seats, "round": scene.match_id,
        "time": scene.now, "scores": [scene.score_a, scene.score_b], "phase": scene.phase, "winner": scene.winner,
        "crates": crates, "pickups": pickups, "throws": throws, "shots": scene.shot_count, "blasts": scene.blast_count,
        "arm_bones": view.skeleton.get_bone_count() if view else 0, "result": hud.results.visible,
        "flash": view.flash.visible if view else false, "recoil": view.recoil if view else 0.0,
        "magazine_offset": view.magazine.position.distance_to(view.seated_magazine) if view else 0.0,
        "respawn_lateness": respawn_lateness})
    return info
