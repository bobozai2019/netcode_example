extends SceneTree

class ProbeCar extends RigidBody3D:
    var input_reads := 0
    var net_input_x: float = 0.0:
        get:
            input_reads += 1
            return net_input_x
    var net_input_z: float = 0.0
    var net_yaw: float = 0.0

const PATHS: Array[NodePath] = [^".:net_input_x", ^".:net_input_z", ^".:net_yaw"]
var failures := 0

func check(ok: bool, message: String) -> void:
    if not ok:
        failures += 1
        push_error(message)

func _initialize() -> void:
    if "--sdk" in OS.get_cmdline_user_args():
        call_deferred("verify_sdk")
        return
    var status := GDExtensionManager.load_extension("res://position_replicator.gdextension")
    if status not in [GDExtensionManager.LOAD_STATUS_OK, GDExtensionManager.LOAD_STATUS_ALREADY_LOADED]:
        quit(1)
        return
    call_deferred("run")

func verify_sdk() -> void:
    # Run inside the installed Photon project. Only the SDK is exercised here.
    if not ClassDB.class_exists("FusionSharedReplicator"):
        push_error("Load the Racing project's Photon extension first.")
        quit(1)
        return
    var car := ProbeCar.new()
    root.add_child(car)
    var rep = ClassDB.instantiate("FusionSharedReplicator")
    car.add_child(rep)
    rep.set_root_replication_mode(1)
    var config = ClassDB.instantiate("FusionReplicationConfig")
    rep.set_replication_config(config)
    var sizes := [int(rep.compute_word_count(car))]
    for path in PATHS:
        config.add_property(path)
        sizes.append(int(rep.compute_word_count(car)))
    print("Photon native AUTO + 0/1/2/3 custom fields -> ", sizes)
    print("Photon native project float_compression = ", ProjectSettings.get_setting("fusion/serialization/float_compression"))
    check(sizes == [15, 16, 17, 18], "Unexpected native SDK layout")
    car.free()
    quit(int(failures > 0))

func run() -> void:
    var a := ProbeCar.new()
    var b := ProbeCar.new()
    root.add_child(a)
    root.add_child(b)
    var sender = ClassDB.instantiate("RacingReplicator")
    var receiver = ClassDB.instantiate("RacingReplicator")
    check(sender.configure(a, PATHS, true), "Could not bind A")
    check(receiver.configure(b, PATHS, false), "Could not bind B")
    check(sender.capture(), "Initial capture failed")
    var initial: PackedInt32Array = sender.scan(1)
    check(receiver.receive(1, initial), "B needs the initial snapshot")
    sender.acknowledge(1)
    var previous: PackedInt32Array = sender.get_words()
    var reads := a.input_reads
    a.position.x = 4.0
    a.net_input_x = 0.75
    check(previous == sender.get_words(), "A's setter changed the network buffer")
    check(sender.capture(), "A capture failed")
    check(a.input_reads == reads + 1, "Expected one custom getter in this reference capture")
    var lost: PackedInt32Array = sender.scan(2)
    print("A wrote position.x=4 and net_input_x=0.75; tick 2 pairs = ", lost)
    check(lost == PackedInt32Array([0, 400, 12, 75]), "Wrong word changes")
    check(b.position.x == 0.0 and b.net_input_x == 0.0, "Dropped packet reached B")
    var retry: PackedInt32Array = sender.scan(3)
    check(retry == lost and receiver.receive(3, retry), "Retry failed")
    check(b.position.x == 4.0 and b.net_input_x == 0.75, "B did not apply both values")
    sender.acknowledge(3)
    check(sender.scan(4).is_empty(), "Acknowledged values were resent")
    check(not receiver.receive(2, lost), "Stale tick accepted")
    print("B after tick 3 = ", b.position, ", input = ", b.net_input_x, ", tick 4 pairs = []")
    a.net_input_x = 0.751
    check(sender.capture() and sender.scan(5).is_empty(), "Equal encoded values caused a delta")
    a.net_input_z = -1.0
    a.net_yaw = 0.5
    a.rotation.y = 0.25
    a.linear_velocity.x = 2.0
    a.angular_velocity.z = -0.5
    check(sender.capture() and receiver.receive(6, sender.scan(6)), "Other fields failed")
    check(b.net_input_z == -1 and b.net_yaw == 0.5 and is_equal_approx(b.rotation.y, 0.25)
        and b.linear_velocity.x == 2 and b.angular_velocity.z == -0.5, "Other fields differ")
    var child := Node3D.new()
    child.name = "Wheel"
    a.add_child(child)
    var extra: Array[NodePath] = [^"Wheel:position"]
    var child_sender = ClassDB.instantiate("RacingReplicator")
    check(child_sender.configure(a, extra, true) and child_sender.capture(), "Child binding failed")
    child.free()
    check(not child_sender.capture(), "Freed target accepted")
    child = Node3D.new()
    child.name = "Wheel"
    child.position.x = 2
    a.add_child(child)
    check(child_sender.capture() and child_sender.get_words()[12] == 200, "Replacement node not rebound")
    a.free()
    b.free()
    quit(int(failures > 0))
