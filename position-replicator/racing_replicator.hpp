#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <vector>

namespace godot {

// Readable subset of Racing replication, with one instance per vehicle and peer.
class RacingReplicator : public RefCounted {
    GDCLASS(RacingReplicator, RefCounted)

    struct Slot {
        Node *target;
        uint64_t instance_id;
        StringName property;
        NodePath path; // The native slot also retains the binding path alongside the getter name.
        Variant::Type type;
        int offset;
        int width;
    };

    uint64_t root_id = 0;
    bool authority = false;
    std::vector<NodePath> paths;
    std::vector<Slot> slots;
    PackedInt32Array words, shadow;
    std::vector<int64_t> changed_at;
    int64_t scanned = 0, acked = 0, applied = 0;

    bool build_slots(std::vector<Slot> &result) const;
    bool validate_targets();

protected:
    static void _bind_methods();

public:
    bool configure(Node *vehicle, const TypedArray<NodePath> &custom, bool is_authority);
    bool capture();
    PackedInt32Array scan(int64_t tick);
    void acknowledge(int64_t tick);
    bool receive(int64_t tick, const PackedInt32Array &pairs);
    PackedInt32Array get_words() const { return words; }
};

} // namespace godot
