#include "racing_replicator.hpp"
#include <godot_cpp/core/class_db.hpp>
#include <cmath>
#include <limits>

using namespace godot;

// This preview's default precision path with project setting 0 uses table[2].
// The demonstration uses that path uniformly for its seven fields.
static constexpr double scale = 100.0;
static bool write_float(PackedInt32Array &buffer, int offset, float value) {
    const double encoded = std::round(double(value) * scale);
    if (!std::isfinite(encoded) || encoded < std::numeric_limits<int32_t>::min()
            || encoded > std::numeric_limits<int32_t>::max()) return false;
    buffer.set(offset, static_cast<int32_t>(encoded));
    return true;
}

static float decode_float(int32_t word) {
    return static_cast<float>(word / scale);
}

bool RacingReplicator::build_slots(std::vector<Slot> &result) const {
    Node *root = Object::cast_to<Node>(ObjectDB::get_instance(root_id));
    if (!root) return false;

    int offset = 0;
    for (const NodePath &path : paths) {
        if (path.is_absolute() || path.get_subname_count() != 1) return false;
        Node *target = root;
        if (path.get_name_count() > 0) {
            target = root->get_node_or_null(NodePath(String(path.get_concatenated_names())));
        }
        if (!target) return false;
        const StringName property = path.get_subname(0);
        for (const Slot &slot : result) {
            if (slot.target == target && slot.property == property) return false;
        }
        // Inspect the declared type without invoking the property's getter.
        Variant::Type type = Variant::NIL;
        const TypedArray<Dictionary> properties = target->get_property_list();
        for (int i = 0; i < properties.size(); ++i) {
            const Dictionary info = properties[i];
            if (StringName(info["name"]) == property) {
                type = static_cast<Variant::Type>(int(info["type"]));
                break;
            }
        }
        if (type != Variant::FLOAT && type != Variant::VECTOR3) return false;
        const int width = type == Variant::VECTOR3 ? 3 : 1;
        result.push_back({target, target->get_instance_id(), property, path, type, offset, width});
        offset += width;
    }
    return true;
}

bool RacingReplicator::configure(Node *vehicle, const TypedArray<NodePath> &custom, bool is_authority) {
    if (root_id || !vehicle || !vehicle->is_class("RigidBody3D")) return false;
    root_id = vehicle->get_instance_id();
    paths = {NodePath(":position"), NodePath(":rotation"),
             NodePath(":linear_velocity"), NodePath(":angular_velocity")};
    for (int i = 0; i < custom.size(); ++i) paths.push_back(custom[i]);
    std::vector<Slot> built;
    if (!build_slots(built)) {
        root_id = 0;
        return false;
    }
    slots.swap(built);
    authority = is_authority;
    const int size = slots.back().offset + slots.back().width;
    words.resize(size);
    words.fill(0);
    shadow = words;
    changed_at.resize(size, 0);
    return true;
}

bool RacingReplicator::validate_targets() {
    if (!root_id) return false;
    for (const Slot &slot : slots) {
        if (ObjectDB::get_instance(slot.instance_id) == slot.target) continue;
        std::vector<Slot> refreshed;
        if (!build_slots(refreshed)) return false;
        for (size_t i = 0; i < slots.size(); ++i) {
            if (slots[i].type != refreshed[i].type) return false;
        }
        slots.swap(refreshed);
        break;
    }
    return true;
}

bool RacingReplicator::capture() {
    if (!authority || !validate_targets()) return false;
    PackedInt32Array next = words;
    for (const Slot &slot : slots) {
        // Read a value through Godot. A getter can execute script and free another node.
        if (ObjectDB::get_instance(slot.instance_id) != slot.target) return false;
        const Variant current = slot.target->get(slot.property);
        if (current.get_type() != slot.type) return false;
        if (slot.type == Variant::FLOAT) {
            if (!write_float(next, slot.offset, float(current))) return false;
        } else {
            const Vector3 vector = current;
            for (int axis = 0; axis < 3; ++axis) {
                if (!write_float(next, slot.offset + axis, vector[axis])) return false;
            }
        }
    }
    words = next;
    return true;
}

PackedInt32Array RacingReplicator::scan(int64_t tick) {
    PackedInt32Array pairs;
    if (!authority || tick <= scanned) return pairs;
    for (int i = 0; i < words.size(); ++i) {
        if (!scanned || words[i] != shadow[i]) {
            shadow.set(i, words[i]);
            changed_at[i] = tick;
        }
        if (changed_at[i] > acked) {
            pairs.push_back(i);
            pairs.push_back(words[i]);
        }
    }
    scanned = tick;
    return pairs;
}

void RacingReplicator::acknowledge(int64_t tick) {
    if (authority && tick > acked && tick <= scanned) acked = tick;
}

bool RacingReplicator::receive(int64_t tick, const PackedInt32Array &pairs) {
    if (authority || tick <= applied || pairs.size() % 2 || !validate_targets()) return false;
    if (!applied && pairs.size() / 2 != words.size()) return false;
    PackedInt32Array next = words;
    std::vector<bool> touched(words.size(), false);
    for (int i = 0; i < pairs.size(); i += 2) {
        const int offset = pairs[i];
        if (offset < 0 || offset >= words.size() || touched[offset]) return false;
        next.set(offset, pairs[i + 1]);
        touched[offset] = true;
    }
    for (const Slot &slot : slots) {
        const int i = slot.offset;
        bool changed = false;
        for (int j = 0; j < slot.width; ++j) changed |= touched[i + j];
        if (!changed) continue;
        if (ObjectDB::get_instance(slot.instance_id) != slot.target) return false;
        if (slot.type == Variant::FLOAT)
            slot.target->set(slot.property, decode_float(next[i]));
        else
            slot.target->set(slot.property, Vector3(decode_float(next[i]),
                    decode_float(next[i + 1]), decode_float(next[i + 2])));
    }
    words = next;
    applied = tick;
    return true;
}

void RacingReplicator::_bind_methods() {
    ClassDB::bind_method(D_METHOD("configure", "vehicle", "custom", "is_authority"), &RacingReplicator::configure);
    ClassDB::bind_method(D_METHOD("capture"), &RacingReplicator::capture);
    ClassDB::bind_method(D_METHOD("scan", "tick"), &RacingReplicator::scan);
    ClassDB::bind_method(D_METHOD("acknowledge", "tick"), &RacingReplicator::acknowledge);
    ClassDB::bind_method(D_METHOD("receive", "tick", "pairs"), &RacingReplicator::receive);
    ClassDB::bind_method(D_METHOD("get_words"), &RacingReplicator::get_words);
}
