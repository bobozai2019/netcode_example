
extends RefCounted

const Rules = preload("res://combat/rules.gd")
const Ledger = preload("res://combat/ledger.gd")
const State = preload("res://actors/state.gd")
const Wire = preload("res://net/channel.gd")
const Code = Wire.Code
const HIT_SIZE := 2
const COMMIT_SIZE := 5
const RECEIPT_SIZE := 11
const RETRY_STEPS := 120
const MAX_RETRIES_PER_PASS := 88
const CONTACT_DAMAGE := 9

var game
var book := Ledger.new()
var attacks: Dictionary[Vector2i, PackedInt32Array] = {}
var pending: Dictionary[Vector4i, int] = {}
var retry_after: Dictionary[Vector4i, int] = {}
var owner_waits: Dictionary[Vector4i, bool] = {}
var owner_projection: Dictionary[int, Vector2i] = {}
var routed: Dictionary[Vector4i, Vector2i] = {}
var receipt_queue := PackedInt32Array()
var early_receipts: Dictionary[int, Array] = {}
var attack_number := 0
var flying: Array[Dictionary] = []
var pulses: Array[Dictionary] = []
var chains: Dictionary[int, Dictionary] = {}
var hazards: Dictionary[Vector2i, Dictionary] = {}
var danger_number := 0
var next_attack := PackedInt32Array([0, 0, 0])
var confirmations_local: Array[float] = []
var confirmations_remote: Array[float] = []
var received_hit_batch_sizes: Array[int] = []
var attack_feedback: Array[float] = []
var danger_reaction: Array[float] = []
var late_dangers := 0
var dropped_old_commits := 0
var hit_flashes: Dictionary[int, int] = {}
var pause_remote_commits := false

func _init(session) -> void:
	game = session

func update(step: int) -> void:
	var mine: State = game.motions.get(game.local_id)
	var life: State = game.vitals.get(game.local_id)
	if mine != null and life != null and life.sync.is_write_ready():
		apply_hazards(mine, life, step)
		if life.hp > 0 and game.auto_attack():
			fire_available(mine, step)
	for index in range(flying.size() - 1, -1, -1):
		var knife := flying[index]
		if step >= int(knife.start) + 50 or int(knife.left) == 0:
			flying.remove_at(index)
			continue
		advance_knife(knife, step, int(knife.player) == game.local_id)
	for index in range(pulses.size() - 1, -1, -1):
		var pulse := pulses[index]
		while int(pulse.segment) < 3 and step >= int(pulse.next):
			halo_pulse(pulse.player, pulse.attack, pulse.origin, pulse.radius, pulse.segment, step)
			pulse.segment += 1
			pulse.next += 18
		if int(pulse.segment) == 3:
			pulses.remove_at(index)
	if step % 15 == 0:
		retry(step)
		for id: int in hit_flashes.keys():
			if int(hit_flashes[id]) < step:
				hit_flashes.erase(id)

func fire_available(mine: State, step: int) -> void:
	var build: PackedInt32Array = game.build_for(game.local_id)
	if step >= next_attack[Rules.Weapon.KNIFE]:
		var nearest := nearest_enemy(mine.position_xz, 16.0)
		if nearest != null:
			var aim := mine.position_xz.direction_to(nearest.position_xz)
			if aim.is_zero_approx():
				aim = mine.facing
			start_attack(Rules.Weapon.KNIFE, mine.position_xz, aim, step)
			next_attack[Rules.Weapon.KNIFE] = step + 34
	if build[2] > 0 and step >= next_attack[Rules.Weapon.HALO]:
		start_attack(Rules.Weapon.HALO, mine.position_xz, mine.facing, step)
		next_attack[Rules.Weapon.HALO] = step + 114
	if build[3] > 0 and step >= next_attack[Rules.Weapon.LIGHTNING]:
		start_attack(Rules.Weapon.LIGHTNING, mine.position_xz, mine.facing, step)
		next_attack[Rules.Weapon.LIGHTNING] = step + 105

func nearest_enemy(origin: Vector2, radius: float, excluded: Dictionary = {}) -> State:
	var nearest: State
	var distance := radius * radius
	for enemy: State in game.enemies.values():
		if enemy.hp <= 0 or excluded.has(enemy.entity_id):
			continue
		var length := origin.distance_squared_to(enemy.observed_position())
		if length < distance or (length == distance and nearest != null and enemy.entity_id < nearest.entity_id):
			nearest = enemy
			distance = length
	return nearest

func start_attack(weapon: int, origin: Vector2, direction: Vector2, step: int, generate := true) -> int:
	var started := Time.get_ticks_usec()
	attack_number += 1
	var build: PackedInt32Array = game.build_for(game.local_id)
	var fields := PackedInt32Array([game.run_id, attack_number, weapon, step, build[0], game.seed ^ attack_number])
	fields.append_array(Wire.pack_point(origin))
	fields.append_array(Wire.pack_point(direction))
	receive(game.local_id, Code.ATTACK, fields)
	game.channel.send(0, Code.ATTACK, fields)
	if generate:
		render_attack(game.local_id, fields, build)
	if generate and weapon == Rules.Weapon.LIGHTNING:
		var selected: Array[State] = []
		var excluded := {}
		var cursor := origin
		for chain in 2 + build[3]:
			var target := nearest_enemy(cursor, 10.0 if chain == 0 else 5.0, excluded)
			if target == null:
				break
			selected.append(target)
			excluded[target.entity_id] = true
			cursor = target.observed_position()
		game.arena.lightning(origin, selected, step)
		if not selected.is_empty():
			var order: Dictionary[int, Vector2] = {}
			for enemy in selected:
				order[enemy.entity_id] = enemy.observed_position()
			chains[attack_number] = {"origin": origin, "order": order, "resolved": {}}
		submit(attack_number, 0, selected)
	game.probe.attack_started(started)
	return attack_number

func receive(sender: int, code: int, fields: PackedInt32Array) -> void:
	match code:
		Code.ATTACK:
			if fields.size() != 10 or not valid_player(sender) or fields[1] <= 0 or fields[2] < 0 or fields[2] > Rules.Weapon.LIGHTNING:
				return
			var key := Vector2i(sender, fields[1])
			var build: PackedInt32Array = game.build_version(sender, fields[4], fields[3])
			if attacks.has(key) or build.is_empty() or (fields[2] > 0 and build[fields[2] + 1] == 0):
				return
			attacks[key] = fields
			if sender != game.local_id:
				render_attack(sender, fields, build)
		Code.HIT:
			if fields.size() >= 5 and valid_player(sender) and game.host:
				route_hit(sender, fields)
		Code.OWNER_HIT:
			if sender == game.host_id and fields.size() >= 6:
				propose(fields)
		Code.COMMIT:
			if fields.size() >= 8 and valid_player(sender) and game.host:
				accept_commit(sender, fields)
		Code.RECEIPT:
			if sender == game.host_id and (fields.size() - 1) % RECEIPT_SIZE == 0:
				for i in range(1, fields.size(), RECEIPT_SIZE):
					receive_receipt(fields.slice(i, i + RECEIPT_SIZE))
		Code.DANGER:
			if fields.size() == 16:
				receive_danger(sender, fields)
		Code.CHAIN:
			if fields.size() >= 6 and fields.size() % 2 == 0 and valid_player(sender):
				var attack: Vector2i = Vector2i(sender, fields[1])
				if attacks.has(attack) and attacks[attack][2] == Rules.Weapon.LIGHTNING:
					var from := Wire.point(fields, 2)
					for i in range(4, fields.size(), 2):
						var to := Wire.point(fields, i)
						game.arena.arc(from, to, game.step)
						from = to

func render_attack(player: int, fields: PackedInt32Array, build: PackedInt32Array) -> void:
	var origin := Wire.point(fields, 6)
	var direction := Wire.point(fields, 8).normalized()
	match fields[2]:
		Rules.Weapon.KNIFE:
			flying.append({"player": player, "attack": fields[1], "origin": origin, "axis": direction,
				"start": fields[3], "elapsed": 0, "left": 2 + build[1], "seen": {}})
		Rules.Weapon.HALO:
			pulses.append({"player": player, "attack": fields[1], "origin": origin,
				"radius": Rules.radius(build[2]), "next": fields[3], "segment": 0})

func halo_pulse(player: int, attack: int, origin: Vector2, radius: float, segment: int, step: int) -> void:
	game.arena.pulse(origin, radius, step)
	if player != game.local_id:
		return
	var selected: Array[State] = []
	for enemy: State in game.enemies.values():
		var area := radius + enemy_radius(enemy)
		if enemy.hp > 0 and origin.distance_squared_to(enemy.observed_position()) <= area * area:
			selected.append(enemy)
	submit(attack, segment, selected)

func advance_knife(knife: Dictionary, step: int, local: bool) -> void:
	var elapsed := maxi(0, step - int(knife.start))
	if elapsed <= int(knife.elapsed):
		return
	var axis: Vector2 = knife.axis
	var from: Vector2 = knife.origin + axis * (0.45 + float(knife.elapsed) * 0.42)
	var to: Vector2 = knife.origin + axis * (0.45 + float(elapsed) * 0.42)
	knife.elapsed = elapsed
	if not local:
		return
	var candidates: Array[State] = []
	for enemy: State in game.enemies.values():
		if enemy.hp <= 0 or knife.seen.has(enemy.entity_id):
			continue
		var point := enemy.observed_position()
		var contact := Geometry2D.get_closest_point_to_segment(point, from, to)
		if contact.distance_squared_to(point) <= pow(enemy_radius(enemy) + 0.22, 2):
			candidates.append(enemy)
	if candidates.is_empty():
		return
	candidates.sort_custom(func(a: State, b: State) -> bool:
		var da := from.distance_squared_to(a.observed_position())
		var db := from.distance_squared_to(b.observed_position())
		return da < db if da != db else a.entity_id < b.entity_id)
	candidates.resize(mini(candidates.size(), int(knife.left)))
	for enemy in candidates:
		knife.seen[enemy.entity_id] = true
	knife.left -= candidates.size()
	submit(knife.attack, 0, candidates)

func submit(attack: int, segment: int, selected: Array[State]) -> void:
	var fields := PackedInt32Array([game.run_id, attack, segment, game.step])
	for enemy in selected:
		var key := Vector4i(game.local_id, attack, enemy.entity_id, segment)
		if not pending.has(key):
			var hit_at := Time.get_ticks_usec()
			pending[key] = hit_at
			retry_after[key] = game.step + RETRY_STEPS
			hit_flashes[enemy.entity_id] = game.step + 8
			var origin := Vector2i(key.x, key.y)
			var attack_info := attacks[origin]
			game.arena.hit(enemy.observed_position(), game.step, Rules.damage(attack_info[2]), hit_at)
		fields.append_array(PackedInt32Array([enemy.entity_id, enemy.generation]))
		if fields.size() >= Wire.MAX_FIELDS:
			game.channel.send(game.host_id, Code.HIT, fields)
			fields.resize(4)
	if fields.size() > 4:
		game.channel.send(game.host_id, Code.HIT, fields)

func route_hit(sender: int, fields: PackedInt32Array) -> void:
	var attack := Vector2i(sender, fields[1])
	if not attacks.has(attack) or (fields.size() - 4) % HIT_SIZE != 0 or not valid_segment(attacks[attack][2], fields[2]):
		return
	received_hit_batch_sizes.append((fields.size() - 4) / 2)
	var by_owner := {}
	for i in range(4, fields.size(), HIT_SIZE):
		var key := Vector4i(sender, fields[1], fields[i], fields[2])
		var record: Dictionary = book.enemies.get(fields[i], {})
		if record.is_empty():
			receipt(key, book.evaluate(key, 0), 0)
			continue
		if book.hits.has(key) or int(record.hp) <= 0:
			routed.erase(key)
			var previous := book.evaluate(key, 0)
			book.commit(key, previous, Vector2.ZERO, 0)
			receipt(key, previous, int(record.owner))
			continue
		var owner: int = game.actual_owner(fields[i])
		routed[key] = Vector2i(owner, int(record.generation))
		if not by_owner.has(owner):
			by_owner[owner] = PackedInt32Array([game.run_id, sender, fields[1], fields[2]])
		var routed: PackedInt32Array = by_owner[owner]
		routed.append_array(PackedInt32Array([fields[i], int(record.generation)]))
		if routed.size() == Wire.MAX_FIELDS:
			game.channel.send(owner, Code.OWNER_HIT, routed)
			routed.resize(4)
		by_owner[owner] = routed
	for owner: int in by_owner:
		if by_owner[owner].size() > 4:
			game.channel.send(owner, Code.OWNER_HIT, by_owner[owner])

func propose(fields: PackedInt32Array) -> void:
	if pause_remote_commits or (fields.size() - 4) % HIT_SIZE != 0:
		return
	var attack := Vector2i(fields[1], fields[2])
	if not attacks.has(attack):
		return
	var damage := Rules.damage(attacks[attack][2])
	var batch := PackedInt32Array([game.run_id, attack.x, attack.y, fields[3]])
	for i in range(4, fields.size(), HIT_SIZE):
		var enemy: State = game.enemies.get(fields[i])
		var key := Vector4i(attack.x, attack.y, fields[i], fields[3])
		if enemy == null or not enemy.sync.is_write_ready() or enemy.generation != fields[i + 1]:
			continue
		if not game.host and owner_waits.has(key):
			continue
		var candidate := book.evaluate(key, damage)
		if not game.host:
			if candidate.x == Ledger.HitResult.APPLIED:
				var snapshot: Vector2i = owner_projection.get(key.z, Vector2i(int(book.enemies[key.z].hp), candidate.z - 1))
				if snapshot.x > 0:
					candidate.y = maxi(0, snapshot.x - damage)
					candidate.z = snapshot.y + 1
					owner_projection[key.z] = Vector2i(candidate.y, candidate.z)
				else:
					candidate = Vector3i(Ledger.HitResult.DEAD, 0, snapshot.y)
			owner_waits[key] = true
		var pre_version := candidate.z - 1 if candidate.x == Ledger.HitResult.APPLIED else candidate.z
		batch.append_array(PackedInt32Array([key.z, fields[i + 1], pre_version, candidate.z, candidate.y]))
		if batch.size() + COMMIT_SIZE > Wire.MAX_FIELDS:
			game.channel.send(game.host_id, Code.COMMIT, batch)
			batch.resize(4)
	if batch.size() > 4:
		game.channel.send(game.host_id, Code.COMMIT, batch)

func accept_commit(sender: int, fields: PackedInt32Array) -> void:
	var attack := Vector2i(fields[1], fields[2])
	if (fields.size() - 4) % COMMIT_SIZE != 0 or not attacks.has(attack) or not valid_segment(attacks[attack][2], fields[3]):
		return
	var damage := Rules.damage(attacks[attack][2])
	for i in range(4, fields.size(), COMMIT_SIZE):
		var id := fields[i]
		var key := Vector4i(attack.x, attack.y, id, fields[3])
		var record: Dictionary = book.enemies.get(id, {})
		if record.is_empty() or int(record.generation) != fields[i + 1] or sender != game.actual_owner(id):
			dropped_old_commits += 1
			continue
		if routed.get(key, Vector2i.ZERO) != Vector2i(sender, fields[i + 1]):
			continue
		var value := book.evaluate(key, damage)
		if value.x == Ledger.HitResult.APPLIED and (fields[i + 2] != value.z - 1 or fields[i + 3] != value.z or fields[i + 4] != value.y):
			# The competing hit was already committed. Reliable receipts precede this retry request.
			game.channel.send(sender, Code.RECEIPT, PackedInt32Array([game.run_id, key.x, key.y, key.z, key.w, -1, 0, 0, sender, 0, 0, 0]))
			continue
		var enemy: State = game.enemies.get(id)
		if enemy == null:
			continue
		book.commit(key, value, enemy.position_xz, game.stone_value(enemy))
		routed.erase(key)
		if value.x == Ledger.HitResult.APPLIED:
			if enemy.sync.is_write_ready():
				enemy.hp = value.y
				enemy.version = value.z
			if value.y == 0:
				game.enemy_killed(enemy)
		receipt(key, value, sender)

func receipt(key: Vector4i, result: Vector3i, owner: int) -> void:
	var p: Vector2 = book.deaths.get(key.z, Vector2.ZERO)
	var value := int(book.stones[key.z].value) if book.stones.has(key.z) else 0
	var fields := PackedInt32Array([key.x, key.y, key.z, key.w, result.x, result.y, result.z, owner, value])
	fields.append_array(Wire.pack_point(p))
	receive_receipt(fields)
	queue_receipt(fields)

func queue_receipt(fields: PackedInt32Array) -> void:
	if receipt_queue.is_empty():
		receipt_queue.append(game.run_id)
	if receipt_queue.size() + fields.size() > Wire.MAX_FIELDS:
		flush_receipts()
		receipt_queue.append(game.run_id)
	receipt_queue.append_array(fields)

func flush_receipts() -> void:
	if not receipt_queue.is_empty():
		game.channel.send(0, Code.RECEIPT, receipt_queue)
		receipt_queue.clear()

func receive_receipt(fields: PackedInt32Array) -> void:
	var key := Vector4i(fields[0], fields[1], fields[2], fields[3])
	owner_waits.erase(key)
	if fields[4] == -1:
		owner_projection.erase(key.z)
		return
	if owner_projection.has(key.z) and int(fields[6]) >= owner_projection[key.z].y:
		owner_projection.erase(key.z)
	var enemy: State = game.enemies.get(key.z)
	if not game.host and fields[4] == Ledger.HitResult.APPLIED:
		if not book.enemies.has(key.z):
			if not early_receipts.has(key.z):
				early_receipts[key.z] = []
			early_receipts[key.z].append(fields)
			return
		book.commit(key, Vector3i(fields[4], fields[5], fields[6]), Wire.point(fields, 9), fields[8])
		if enemy != null and enemy.sync.is_write_ready():
			enemy.hp = fields[5]
			enemy.version = fields[6]
		if enemy != null and fields[5] == 0:
			game.arena.fall(enemy.observed_position(), game.step)
	if fields[4] == Ledger.HitResult.APPLIED and key.x != game.local_id and enemy != null:
		hit_flashes[key.z] = game.step + 8
	if key.x == game.local_id and chains.has(key.y):
		resolve_chain(key.y, key.z, fields[4] in [Ledger.HitResult.APPLIED, Ledger.HitResult.DUPLICATE])
	if pending.has(key):
		var latency := float(Time.get_ticks_usec() - pending[key]) / 1000.0
		if fields[7] == game.local_id:
			confirmations_local.append(latency)
		else:
			confirmations_remote.append(latency)
		pending.erase(key)
		retry_after.erase(key)

func resolve_chain(attack: int, target: int, hit: bool) -> void:
	var path := chains[attack]
	if not path.order.has(target):
		return
	path.resolved[target] = hit
	if path.resolved.size() != path.order.size():
		return
	var fields := PackedInt32Array([game.run_id, attack])
	fields.append_array(Wire.pack_point(path.origin))
	for id: int in path.order:
		if not bool(path.resolved[id]):
			continue
		var point: Vector2 = path.order[id]
		fields.append_array(Wire.pack_point(point))
		if fields.size() == Wire.MAX_FIELDS:
			game.channel.send(0, Code.CHAIN, fields)
			fields.resize(2)
			fields.append_array(Wire.pack_point(point))
	if fields.size() > 4:
		game.channel.send(0, Code.CHAIN, fields)
	chains.erase(attack)

func replay_early_receipts(id: int) -> void:
	for fields: PackedInt32Array in early_receipts.get(id, []):
		receive_receipt(fields)
	early_receipts.erase(id)

func retry(step: int) -> void:
	if game.channel.backlog() > 96:
		return
	var groups := {}
	var added := 0
	for key: Vector4i in pending.keys():
		if added >= MAX_RETRIES_PER_PASS:
			break
		if step < int(retry_after.get(key, 0)):
			continue
		added += 1
		retry_after[key] = step + RETRY_STEPS
		var group := Vector2i(key.y, key.w)
		if not groups.has(group):
			groups[group] = PackedInt32Array([game.run_id, key.y, key.w, step])
		var fields: PackedInt32Array = groups[group]
		fields.append_array(PackedInt32Array([key.z, game.generation(key.z)]))
		if fields.size() == Wire.MAX_FIELDS:
			game.channel.send(game.host_id, Code.HIT, fields)
			fields.resize(4)
		groups[group] = fields
	for fields: PackedInt32Array in groups.values():
		if fields.size() > 4:
			game.channel.send(game.host_id, Code.HIT, fields)

func start_danger(source: int, origin: Vector2, end: Vector2, radius: float, lead: int, length: int, damage: int) -> void:
	danger_number += 1
	var step: int = game.step
	var fields := PackedInt32Array([game.run_id, danger_number, source, step, step + lead, step + lead + length,
		damage, roundi(radius * 1000.0), 0, game.generation(source)])
	fields.append_array(Wire.pack_point(origin))
	fields.append_array(Wire.pack_point(end))
	fields.append_array(PackedInt32Array([0, 0]))
	receive_danger(game.local_id, fields)
	game.channel.send(0, Code.DANGER, fields)

func receive_danger(sender: int, fields: PackedInt32Array) -> void:
	var source := fields[2]
	var id := Vector2i(sender, fields[1])
	if hazards.has(id) or fields[9] != game.generation(source):
		return
	if source == 0:
		if sender != game.host_id:
			return
	else:
		var enemy: State = game.enemies.get(source)
		if enemy == null or (sender != game.host_id and sender != enemy.controller):
			return
	if game.step >= fields[5]:
		late_dangers += 1
		return
	danger_reaction.append(maxf(0.0, (fields[4] - game.step) * 1000.0 / Rules.HZ))
	hazards[id] = {"origin": Wire.point(fields, 10), "end": Wire.point(fields, 12), "radius": fields[7] * 0.001,
		"begin": fields[3], "active": fields[4], "end_step": fields[5], "damage": fields[6], "spent": false}

func apply_hazards(motion: State, life: State, step: int) -> void:
	for id: Vector2i in hazards.keys():
		var danger := hazards[id]
		if step >= int(danger.end_step):
			hazards.erase(id)
		elif step >= int(danger.active) and not bool(danger.spent):
			danger.spent = true
			var contact: Vector2 = danger.origin
			if danger.origin != danger.end:
				contact = Geometry2D.get_closest_point_to_segment(motion.position_xz, danger.origin, danger.end)
			if motion.position_xz.distance_squared_to(contact) <= pow(float(danger.radius) + Rules.PLAYER_RADIUS, 2):
				hurt(life, int(danger.damage), step)
	if life.hp <= 0 or step < life.invulnerable_until or game.ignore_contact():
		return
	for enemy: State in game.enemies.values():
		if enemy.hp > 0 and motion.position_xz.distance_squared_to(enemy.observed_position()) <= pow(enemy_radius(enemy) + Rules.PLAYER_RADIUS, 2):
			hurt(life, CONTACT_DAMAGE, step)
			return

func hurt(life: State, damage: int, step: int) -> void:
	if not game.is_stress_test() and life.hp > 0 and step >= life.invulnerable_until:
		life.hp = maxi(0, life.hp - damage)
		life.version += 1
		life.invulnerable_until = step + 46
		game.probe.hurt(step, life.hp)

func valid_player(player: int) -> bool:
	return game.motions.has(player) and game.members.has(player)

func valid_segment(weapon: int, segment: int) -> bool:
	return segment == 0 or (weapon == Rules.Weapon.HALO and segment in [1, 2])

static func enemy_radius(enemy: State) -> float:
	return enemy.enemy_type.radius
