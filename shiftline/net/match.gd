extends Node3D

const SceneReplica = preload("res://addons/netcode/scene_replicator.gd")

signal ready_to_play
signal ended(reason: String)
signal hit_confirmed
signal feedback(message: String)

const Rules = preload("config.gd")
const Arena = preload("../arena/warehouse.gd")
const Player = preload("../actors/player/player.gd")
const Grenade = preload("../actors/grenade/grenade.gd")
const GrenadeScene = preload("../actors/grenade/grenade.tscn")
const TracerScene = preload("../effects/tracer.tscn")
const MuzzleFlashScene = preload("../effects/muzzle_flash.tscn")
const BlastScene = preload("../effects/blast.tscn")
const CONNECT_SECONDS := 9.0

var match_id := 0
var phase := Rules.Phase.PLAY
var score_a := 0
var score_b := 0
var winner := -1
var restart_at := 0.0
var host_ip := ""
var port := 0
var room := NetcodeRoom.new()
@onready var sync: SceneReplica = $Sync
@onready var warehouse: Arena = $Warehouse
var slots: Array[Player] = []
var grenades: Dictionary[int, Grenade] = {}
var static_replicas: Array[SceneReplica] = []
var grenade_schema := 0
var is_host := false
var now := 0.0
var local_player_id := 0
var local_slot: Player
var nickname := ""
var frame_rtt := 0.0
var seats := 0
var opened := false
var admitted := false
var playing := false
var deadline := 0
var ping_at := 0.0
var next_tied_team := 0
var shot_seq := 0
var newest_shot := 0
var blast_seq := 0
var newest_blast := 0
var shot_count := 0
var blast_count := 0

func _ready() -> void:
    static_replicas.append(sync)
    for crate in warehouse.crates:
        static_replicas.append(crate.sync)
    for pickup in warehouse.pickups:
        static_replicas.append(pickup.sync)
    # Keep PlayerSlot paths stable so clients using the previous scene can bind them.
    for child in get_children():
        if child is Player:
            slots.append(child)
            static_replicas.append(child.sync)
    var prototype := GrenadeScene.instantiate()
    grenade_schema = int(prototype.get_node("Sync").definition().id)
    prototype.free()

func connect_room(host: bool, address: String, endpoint_port: int, profile: String) -> String:
    is_host = host
    host_ip = address
    port = endpoint_port
    nickname = clean_nickname(profile)
    room.register_broadcast_receiver(self)
    var problem := room.open(self, host, address, port, Rules.CAPACITY, [GrenadeScene])
    if not problem.is_empty():
        return problem
    if host:
        if not room.game.set_player_ttl(0) or not room.game.start():
            room.close()
            return "Could not start the room."
        new_match()
        for replica in static_replicas:
            if room.spawn(replica) == 0:
                room.close()
                return "Could not initialize the room scene."
    opened = true
    deadline = Time.get_ticks_msec() + int(CONNECT_SECONDS * 1000)
    return ""

func close() -> void:
    opened = false
    room.close()

func _exit_tree() -> void:
    if opened: close()

func _physics_process(delta: float) -> void:
    if not opened:
        return
    var frame := room.advance()
    if not frame.get("round", 0):
        if admitted or Time.get_ticks_msec() >= deadline:
            close()
            ended.emit("The host closed the room or the connection was lost." if admitted
                else "Could not join. Check the LAN address, port and available seats.")
        return
    admitted = true
    now = frame.time
    seats = frame.seats
    local_player_id = frame.player
    frame_rtt = frame.rtt
    if is_host:
        if not playing and not all_baselines():
            if Time.get_ticks_msec() >= deadline:
                close()
                ended.emit("The room did not finish loading. Try hosting again.")
            return
        update_members()
        if phase == Rules.Phase.RESULTS and now >= restart_at:
            new_match()
        if phase == Rules.Phase.PLAY:
            tick_play(delta)
    else:
        update_grenade_replicas(frame.objects)
    local_slot = slot_for(local_player_id)
    if not playing and local_slot and (is_host or all_baselines()):
        playing = true
        if is_host:
            apply_profile(local_player_id, nickname)
        else:
            room.rpc_to(room.TARGET_MASTER, set_profile, nickname)
        ready_to_play.emit()
    if not playing and Time.get_ticks_msec() >= deadline:
        close()
        ended.emit("The room did not finish loading. Try joining again.")
        return
    if playing and not is_host and frame_rtt > 0 and now >= ping_at:
        ping_at = now + 1.0
        room.rpc_to(room.TARGET_MASTER, report_ping, roundi(frame_rtt * 1000))

func _process(delta: float) -> void:
    for slot in slots:
        slot.present(delta, slot == local_slot, is_host, now)
    for crate in warehouse.crates:
        crate.present()
    for pickup in warehouse.pickups:
        pickup.present(now)
    for grenade: Grenade in grenades.values():
        grenade.present(delta, match_id, is_host)

func all_baselines() -> bool:
    if match_id <= 0:
        return false
    for replica in static_replicas:
        if not replica.initialized or int(replica.replication_root().get("match_id")) != match_id:
            return false
    return true

func update_members() -> void:
    var audience: PackedInt64Array = room.game.routing_info(0, true).get("audience", PackedInt64Array())
    var members := {}
    var count := [0, 0]
    for slot in slots:
        if slot.active and slot.player_id not in audience:
            slot.vacate()
        if slot.active:
            members[slot.player_id] = true
            count[slot.team] += 1
    for member in audience:
        if members.has(member):
            continue
        var team := next_tied_team
        if count[0] == count[1]:
            next_tied_team = 1 - next_tied_team
        else:
            team = 0 if count[0] < count[1] else 1
        for slot in slots:
            if not slot.active:
                slot.occupy(member, team, match_id, spawn_for(team, slot.slot_index), member == local_player_id)
                if phase == Rules.Phase.RESULTS:
                    slot.alive = false
                    slot.collision_layer = 0
                count[team] += 1
                break

func slot_for(id: int) -> Player:
    if id > 0:
        for slot in slots:
            if slot.active and slot.player_id == id:
                return slot
    return null

func spawn_for(team: int, index: int) -> Vector3:
    for step in 4:
        var spot := warehouse.spawn_point(team, (index + step) % 4)
        var clear := true
        for other in slots:
            if other.active and other.alive and other.position.distance_squared_to(spot) < 1.1:
                clear = false
                break
        if clear:
            return spot
    return warehouse.spawn_point(team, index % 4) + Vector3(1 if team == 0 else -1, 0, 0)

func new_match() -> void:
    for id in grenades.keys():
        remove_grenade(id)
    match_id += 1
    phase = Rules.Phase.PLAY
    winner = -1
    score_a = 0
    score_b = 0
    restart_at = 0.0
    for slot in slots:
        slot.match_id = match_id
        slot.kills = 0
        slot.deaths = 0
        if slot.active:
            slot.spawn_life(match_id, spawn_for(slot.team, slot.slot_index))
    for crate in warehouse.crates:
        crate.reset_for(match_id)
    for pickup in warehouse.pickups:
        pickup.reset_for(match_id)

func tick_play(delta: float) -> void:
    for slot in slots:
        if not slot.active:
            continue
        if not slot.alive:
            if slot.respawn_at > 0.0 and now >= slot.respawn_at:
                slot.spawn_life(match_id, spawn_for(slot.team, slot.slot_index))
            continue
        slot.simulate(delta, now, warehouse.ladders, warehouse.deck_height)
        if slot.position.y < -5:
            slot.position = spawn_for(slot.team, slot.slot_index)
            slot.velocity = Vector3.ZERO
        tick_actions(slot)
        if phase != Rules.Phase.PLAY:
            return
    for pickup in warehouse.pickups:
        if not pickup.available and now >= pickup.refresh_at:
            pickup.reset_for(match_id)
    for id in grenades.keys():
        var grenade := grenades[id]
        if now >= grenade.detonate_at:
            blast(grenade)
            remove_grenade(id)
        else:
            grenade.simulate(delta)
        if phase != Rules.Phase.PLAY:
            return

func tick_actions(slot: Player) -> void:
    if slot.throw_at > 0 and now >= slot.throw_at:
        launch_grenade(slot)
        slot.throw_at = 0
    if slot.action != Rules.Action.IDLE and now >= slot.action_until:
        if slot.action == Rules.Action.RELOAD:
            var rounds := mini(slot.reserve, Rules.MAGAZINE - slot.magazine)
            slot.magazine += rounds
            slot.reserve -= rounds
        slot.set_action(Rules.Action.IDLE, 0)
    var wants_fire := slot.tap_pending or slot.trigger or (slot.input_buttons & Rules.Buttons.FIRE) != 0
    slot.tap_pending = false
    if wants_fire and now >= slot.next_shot_at:
        if slot.action in [Rules.Action.IDLE, Rules.Action.FIRE] and slot.magazine > 0:
            fire(slot)

func fire(slot: Player) -> void:
    slot.magazine -= 1
    slot.next_shot_at = now + Rules.SHOT_INTERVAL
    slot.set_action(Rules.Action.FIRE, now + 0.15)
    var start := slot.global_position + Vector3.UP * slot.eye_height()
    var endpoint := start + slot.facing() * 75
    var query := PhysicsRayQueryParameters3D.create(start, endpoint, 3, [slot.get_rid()])
    var impact := get_world_3d().direct_space_state.intersect_ray(query)
    var hit_type := 0
    if not impact.is_empty():
        endpoint = impact.position
        var collider: Node = impact.collider
        if collider.has_meta("player"):
            hit_type = int(damage_player(collider.get_meta("player"), slot.player_id, slot.team, Rules.SHOT_DAMAGE))
        elif collider.has_meta("crate"):
            collider.get_meta("crate").damage(Rules.SHOT_DAMAGE)
            hit_type = 2
    shot_seq += 1
    var muzzle := start + slot.facing() * 0.5 + Basis(Vector3.UP, slot.yaw).x * 0.18 - Vector3.UP * 0.17
    show_shot(match_id, slot.player_id, shot_seq, muzzle, endpoint, hit_type)
    room.rpc(shot_fx, match_id, slot.player_id, shot_seq, muzzle, endpoint, hit_type)

func damage_player(victim: Player, attacker: int, team: int, amount: int) -> bool:
    if not victim.active or not victim.alive or victim.team == team or phase != Rules.Phase.PLAY:
        return false
    victim.hp = maxi(0, victim.hp - amount)
    if victim.hp > 0:
        return true
    victim.alive = false
    victim.deaths += 1
    victim.clear_input()
    victim.velocity = Vector3.ZERO
    victim.collision_layer = 0
    victim.respawn_at = now + Rules.RESPAWN_SECONDS
    victim.set_action(Rules.Action.DOWN, victim.respawn_at)
    var instigator := slot_for(attacker)
    if instigator:
        instigator.kills += 1
    if team == 0:
        score_a += 1
    else:
        score_b += 1
    if maxi(score_a, score_b) >= Rules.WIN_SCORE:
        winner = team
        phase = Rules.Phase.RESULTS
        restart_at = now + Rules.RESULTS_SECONDS
        for id in grenades.keys():
            remove_grenade(id)
    return true

func launch_grenade(slot: Player) -> void:
    var grenade := GrenadeScene.instantiate() as Grenade
    grenade.match_id = match_id
    grenade.thrower_id = slot.player_id
    grenade.thrower_team = slot.team
    grenade.position = slot.position + Vector3.UP * slot.eye_height() + slot.throw_dir * 0.42
    grenade.velocity = slot.throw_dir * 9.0 + Vector3.UP * 3
    grenade.detonate_at = now + Rules.GRENADE_FUSE
    add_child(grenade)
    var id := room.spawn(grenade.sync)
    if id > 0:
        grenades[id] = grenade
    else:
        grenade.queue_free()
        slot.grenades = mini(slot.grenades + 1, Rules.MAX_GRENADES)

func blast(grenade: Grenade) -> void:
    var center := grenade.global_position
    for slot in slots:
        var point := slot.global_position + Vector3.UP * 0.75
        var distance := center.distance_to(point)
        if slot.active and slot.alive and distance < Rules.BLAST_RADIUS and can_reach(center, point):
            damage_player(slot, grenade.thrower_id, grenade.thrower_team, roundi(115 - 18 * distance))
    for crate in warehouse.crates:
        if (not crate.destroyed and crate.global_position.distance_to(center) < Rules.BLAST_RADIUS
                and can_reach(center, crate.global_position + Vector3.UP * 0.7, [crate.cover.get_rid()])):
            crate.damage(Rules.CRATE_HEALTH)
    blast_seq += 1
    show_blast(match_id, blast_seq, center)
    room.rpc(blast_fx, match_id, blast_seq, center)

func remove_grenade(id: int) -> void:
    if not grenades.has(id):
        return
    var grenade := grenades[id]
    grenades.erase(id)
    if is_host:
        room.game.destroy_object(id)
    grenade.sync.unbind()
    grenade.queue_free()

func update_grenade_replicas(ids: PackedInt32Array) -> void:
    for id in grenades.keys():
        if id not in ids:
            remove_grenade(id)
    for id in ids:
        if grenades.has(id) or room.game.routing_info(id, false).get("schema", 0) != grenade_schema:
            continue
        var grenade := GrenadeScene.instantiate() as Grenade
        add_child(grenade)
        if room.bind_replica(grenade.sync, id):
            grenades[id] = grenade
        else:
            grenade.queue_free()

func can_reach(from: Vector3, to: Vector3, exclude: Array[RID] = []) -> bool:
    var query := PhysicsRayQueryParameters3D.create(from, to, 1, exclude)
    return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func nearest_pickup(slot: Player) -> Node3D:
    var best: Node3D
    var distance := Rules.PICKUP_RANGE
    for pickup in warehouse.pickups:
        var range_to := slot.position.distance_to(pickup.position)
        if pickup.available and range_to < distance:
            best = pickup
            distance = range_to
    return best

func send_move(life: int, seq: int, buttons: int, move: Vector2, yaw: float, pitch: float) -> void:
    if is_host:
        accept_move(local_player_id, match_id, life, seq, buttons, move, yaw, pitch)
    else:
        room.rpc_to(room.TARGET_MASTER, move_input, match_id, life, seq, buttons, move, yaw, pitch)

func send_action(life: int, seq: int, kind: int, target_id: int, generation: int, aim: Vector3) -> void:
    if is_host:
        accept_action(local_player_id, match_id, life, seq, kind, target_id, generation, aim)
    else:
        room.rpc_to(room.TARGET_MASTER, action_request, match_id, life, seq, kind, target_id, generation, aim)

static func clean_nickname(profile: String) -> String:
    var safe := ""
    for character in profile.strip_edges():
        if character.unicode_at(0) >= 32 and character.unicode_at(0) != 127:
            if (safe + character).to_utf8_buffer().size() > 32: break
            safe += character
    return safe

func apply_profile(sender: int, profile: String) -> void:
    var slot := slot_for(sender)
    var safe := clean_nickname(profile)
    if slot and not safe.is_empty():
        slot.nickname = safe

func accept_move(sender: int, round_id: int, life: int, seq: int, buttons: int, move: Vector2, yaw: float, pitch: float) -> void:
    var slot := slot_for(sender)
    if not slot or not slot.alive or round_id != match_id or slot.life_id != life or seq <= slot.ack_input_seq:
        return
    if phase != Rules.Phase.PLAY or not move.is_finite() or not is_finite(yaw) or not is_finite(pitch):
        return
    slot.ack_input_seq = seq
    slot.input_move = move.limit_length()
    slot.input_buttons = buttons & 7
    if (buttons & Rules.Buttons.FIRE) == 0:
        slot.trigger = false
    slot.input_at = now
    slot.yaw = wrapf(yaw, -PI, PI)
    slot.pitch = clampf(pitch, -1.42, 1.42)

func accept_action(sender: int, round_id: int, life: int, seq: int, kind: int, target_id: int, generation: int, aim: Vector3) -> void:
    var slot := slot_for(sender)
    var result := Rules.Result.STALE
    if slot and slot.alive and round_id == match_id and slot.life_id == life and phase == Rules.Phase.PLAY:
        if seq > slot.request_seq:
            result = run_action(slot, kind, target_id, generation, aim)
            slot.request_seq = seq
            slot.request_result = result
        elif seq == slot.request_seq:
            result = slot.request_result
    if sender == local_player_id:
        action_result(round_id, life, seq, result)
    else:
        room.rpc_to_player(sender, action_result, round_id, life, seq, result)

func run_action(slot: Player, kind: int, target_id: int, generation: int, aim: Vector3) -> int:
    match kind:
        Rules.Request.FIRE_START:
            slot.trigger = true
            if slot.magazine == 0:
                return Rules.Result.EMPTY
            # Preserve short clicks until the authoritative simulation step.
            slot.tap_pending = true
        Rules.Request.FIRE_STOP:
            slot.trigger = false
            slot.input_buttons &= ~Rules.Buttons.FIRE
        Rules.Request.RELOAD:
            if slot.action in [Rules.Action.RELOAD, Rules.Action.THROW] or slot.magazine == Rules.MAGAZINE:
                return Rules.Result.BUSY
            if slot.reserve == 0:
                return Rules.Result.EMPTY
            slot.set_action(Rules.Action.RELOAD, now + Rules.RELOAD_SECONDS)
        Rules.Request.THROW:
            if slot.action in [Rules.Action.RELOAD, Rules.Action.THROW]:
                return Rules.Result.BUSY
            if slot.grenades == 0:
                return Rules.Result.EMPTY
            slot.grenades -= 1
            slot.set_action(Rules.Action.THROW, now + Rules.THROW_SECONDS)
            slot.throw_at = now + Rules.THROW_RELEASE
            slot.throw_dir = slot.facing()
            if aim.is_finite() and aim.length_squared() > 0.5 and slot.throw_dir.dot(aim.normalized()) > 0.79:
                slot.throw_dir = aim.normalized()
        Rules.Request.PICKUP:
            if target_id < 0 or target_id >= warehouse.pickups.size():
                return Rules.Result.UNAVAILABLE
            var pickup := warehouse.pickups[target_id]
            if (not pickup.available or pickup.generation != generation or pickup.match_id != match_id
                    or slot.position.distance_to(pickup.position) > Rules.PICKUP_RANGE
                    or not can_reach(slot.position + Vector3.UP * 0.7, pickup.position + Vector3.UP * 0.35)):
                return Rules.Result.UNAVAILABLE
            if pickup.kind == Rules.Pickup.AMMO:
                if slot.reserve >= Rules.MAX_RESERVE: return Rules.Result.BUSY
                slot.reserve = mini(Rules.MAX_RESERVE, slot.reserve + 45)
            else:
                if slot.grenades >= Rules.MAX_GRENADES: return Rules.Result.BUSY
                slot.grenades += 1
            pickup.available = false
            pickup.refresh_at = now + Rules.PICKUP_SECONDS
        _:
            return Rules.Result.STALE
    return Rules.Result.ACCEPTED

@rpc("any_peer", "call_remote", "reliable")
func set_profile(profile: String) -> void:
    if is_host: apply_profile(room.get_rpc_sender(), profile)

@rpc("any_peer", "call_remote", "unreliable")
func report_ping(ping_ms: int) -> void:
    var slot := slot_for(room.get_rpc_sender())
    if is_host and slot and ping_ms >= 0 and ping_ms <= 10000:
        slot.ping_ms = ping_ms

@rpc("any_peer", "call_remote", "unreliable")
func move_input(round_id: int, life: int, seq: int, buttons: int, move: Vector2, yaw: float, pitch: float) -> void:
    if is_host: accept_move(room.get_rpc_sender(), round_id, life, seq, buttons, move, yaw, pitch)

@rpc("any_peer", "call_remote", "reliable")
func action_request(round_id: int, life: int, seq: int, kind: int, target_id: int, generation: int, aim: Vector3) -> void:
    if is_host: accept_action(room.get_rpc_sender(), round_id, life, seq, kind, target_id, generation, aim)

@rpc("authority", "call_remote", "reliable")
func action_result(round_id: int, life: int, _seq: int, result: int) -> void:
    if round_id == match_id and local_slot and life == local_slot.life_id:
        if result == Rules.Result.EMPTY: feedback.emit("No ammunition available")
        if result == Rules.Result.UNAVAILABLE: feedback.emit("Supply unavailable")

@rpc("authority", "call_remote", "unreliable")
func shot_fx(round_id: int, shooter: int, seq: int, muzzle: Vector3, endpoint: Vector3, hit_type: int) -> void:
    show_shot(round_id, shooter, seq, muzzle, endpoint, hit_type)

func show_shot(round_id: int, shooter: int, seq: int, muzzle: Vector3, endpoint: Vector3, hit_type: int) -> void:
    if round_id != match_id or seq <= newest_shot:
        return
    newest_shot = seq
    shot_count += 1
    var own_shot := shooter == local_player_id
    if own_shot:
        if hit_type > 0:
            hit_confirmed.emit()
        # The first-person rifle supplies its own flash. Keep the world tracer outside the viewmodel.
        muzzle = muzzle.move_toward(endpoint, 0.8)
    else:
        var remote := slot_for(shooter)
        if remote and remote.soldier.rifle and remote.soldier.rifle.is_visible_in_tree():
            muzzle = remote.soldier.rifle.to_global(Rules.RIFLE_MUZZLE)
    var length := muzzle.distance_to(endpoint)
    if length < 0.01:
        return
    var tracer := TracerScene.instantiate() as MeshInstance3D
    tracer.position = (muzzle + endpoint) * 0.5
    add_child(tracer)
    tracer.look_at(endpoint, Vector3.RIGHT if absf((muzzle - endpoint).normalized().y) > 0.99 else Vector3.UP)
    tracer.scale.z = length
    get_tree().create_timer(0.058).timeout.connect(tracer.queue_free)
    if not own_shot:
        var flash := MuzzleFlashScene.instantiate() as MeshInstance3D
        flash.position = muzzle
        add_child(flash)
        get_tree().create_timer(0.046).timeout.connect(flash.queue_free)

@rpc("authority", "call_remote", "unreliable")
func blast_fx(round_id: int, seq: int, center: Vector3) -> void:
    show_blast(round_id, seq, center)

func show_blast(round_id: int, seq: int, center: Vector3) -> void:
    if round_id != match_id or seq <= newest_blast:
        return
    newest_blast = seq
    blast_count += 1
    var effect := BlastScene.instantiate() as Node3D
    effect.position = center
    add_child(effect)
    var animation := effect.get_node("AnimationPlayer") as AnimationPlayer
    animation.animation_finished.connect(func(_name: StringName) -> void: effect.queue_free())
