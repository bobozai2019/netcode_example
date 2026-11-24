@tool
class_name NetcodeReplicatedObject
extends Node

# Attach beneath the replicated root. Configure properties in schema order.
# With an empty property list, a native 2D/3D rigid body uses the body.cfg/body3d.cfg contract.
@export var properties: Array[NodePath] = []
@export var teleport_distance := 100.0
@export var teleport_angle_degrees := 15.0
var teleport_generation := 0
var phase := 0
var game: NetcodeGame
var object_id := 0
var body_adapter
var initialized := false
var _body_custom:Array=[]

func replication_root() -> Node:
    return get_parent()

func bind(session: NetcodeGame, id: int) -> bool:
    unbind()
    var root := replication_root()
    if session == null or id <= 0 or root == null: return false
    if _uses_body():
        body_adapter = _make_body(root)
        if body_adapter == null: return false
    for path in field_paths():
        if path.is_absolute() or path.get_subname_count() < 1: return false
        var target := _target(path)
        if target == null or (target != root and not root.is_ancestor_of(target)): return false
        if String(path.get_subname(0)) not in target: return false
    var key := "netcode_replica_%d" % id
    if session.has_meta(key) and session.get_meta(key).get_ref() != null: return false
    session.set_meta(key,weakref(self))
    game = session
    object_id = id
    return true

func unbind() -> void:
    if game != null:
        game.remove_meta("netcode_replica_%d" % object_id)
        game.unbind_replica(object_id)
    game = null
    body_adapter = null
    object_id = 0
    initialized = false
    _body_custom.clear()

func reference() -> int:
    return game.field_reference(object_id) if game != null else 0

func resolve_node(handle: int) -> Node:
    if game == null: return null
    var id := game.resolve_field(handle)
    var key := "netcode_replica_%d" % id
    if id == 0 or not game.has_meta(key): return null
    var replica: Node = game.get_meta(key).get_ref()
    return replica.replication_root() if replica != null else null

func _exit_tree() -> void:
    unbind()

func _target(path: NodePath) -> Node:
    var names := path.get_concatenated_names()
    var root := replication_root()
    if root == null: return null
    return root if names == &"" or names == &"." else root.get_node_or_null(NodePath(names))

func _uses_body() -> bool:
    return properties.is_empty()

func _make_body(root: Node):
    if root is RigidBody3D: return preload("forecast_body_3d.gd").new()
    if root is RigidBody2D: return preload("forecast_body.gd").new()
    return null

func field_paths() -> Array[NodePath]:
    return properties

func _read_member(target: Node, path: NodePath) -> Variant:
    return target.get_indexed(NodePath(":"+String(path.get_concatenated_subnames())))

func _write_member(target: Node, path: NodePath, value: Variant) -> void:
    target.set_indexed(NodePath(":"+String(path.get_concatenated_subnames())),value)

func sample_fields() -> Array:
    var fields: Array = []
    if _uses_body():
        var adapter = body_adapter if body_adapter != null else _make_body(replication_root())
        if adapter == null: return []
        fields = adapter.sample(replication_root(),teleport_generation,phase)
    for path in field_paths():
        var target := _target(path)
        if target == null: return []
        fields.append(_read_member(target,path))
    return fields

func _before_apply(_baseline: bool) -> void:
    pass

func _physics_process(_dt: float) -> void:
    if game == null or Engine.is_editor_hint(): return
    var body := replication_root()
    var sampled := sample_fields()
    var change := game.sync_replica(object_id,sampled,body_adapter != null)
    if change.is_empty():
        if body_adapter!=null and not _body_custom.is_empty() and sampled.slice(7)!=_body_custom:
            var state:=game.routing_info(object_id,false)
            if not state.is_empty() and state.player!=state.writer:
                _before_apply(false)
                var custom:=field_paths()
                for i in custom.size(): _write_member(_target(custom[i]),custom[i],_body_custom[i])
        return
    _before_apply(change.baseline)
    var fields: Array = change.fields
    if body_adapter != null:
        _body_custom=fields.slice(7)
        var snap: bool = change.baseline
        if teleport_distance > 0 and sampled[0].distance_to(fields[0]) > teleport_distance: snap = true
        var angle: float
        if body is RigidBody3D: angle = sampled[1].angle_to(fields[1])
        else: angle = absf(angle_difference(sampled[1],fields[1]))
        if teleport_angle_degrees > 0 and rad_to_deg(angle) > teleport_angle_degrees: snap = true
        if snap: body_adapter.generation = ~int(fields[5])
        teleport_generation = fields[5]
        phase = fields[6]
        body_adapter.apply(body,fields,change.age)
    var offset := 7 if body_adapter != null else 0
    var paths := field_paths()
    for i in paths.size():
        _write_member(_target(paths[i]),paths[i],fields[offset+i])
    initialized = true
