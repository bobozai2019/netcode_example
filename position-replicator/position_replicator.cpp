#include "position_replicator.hpp"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

PositionReplicator::PositionReplicator() {
    // 旧场景没有 property_paths 时，仍然采集父节点的位置。
    bindings.push_back({NodePath(".:position"), NodePath("."), StringName("position")});
}

void PositionReplicator::set_property_paths(const TypedArray<NodePath> &paths) {
    bindings.clear();
    sampled_values.clear();
    for (int64_t i = 0; i < paths.size(); ++i) {
        const NodePath path = paths[i];
        if (path.is_absolute() || path.get_subname_count() != 1) {
            UtilityFunctions::push_warning("Expected a relative node:property path: ", path);
            continue;
        }
        const NodePath relative_node = path.get_name_count() == 0
                ? NodePath(".") : NodePath(String(path.get_concatenated_names()));
        bindings.push_back({path, relative_node, path.get_subname(0)});
    }
}

TypedArray<NodePath> PositionReplicator::get_property_paths() const {
    TypedArray<NodePath> paths;
    for (const Binding &binding : bindings) {
        paths.push_back(binding.path);
    }
    return paths;
}

void PositionReplicator::_enter_tree() {
    root = Object::cast_to<Node3D>(get_parent());
    set_physics_process(root != nullptr);
    if (!root) {
        UtilityFunctions::push_warning("PositionReplicator needs a Node3D parent.");
    }
}

void PositionReplicator::_exit_tree() {
    root = nullptr;
}

void PositionReplicator::_physics_process(double) {
    if (!root) {
        return;
    }

    Dictionary frame;
    for (const Binding &binding : bindings) {
        Node *node = root->get_node_or_null(binding.relative_node);
        if (node) {
            frame[String(binding.path)] = node->get(binding.property).duplicate(true);
        }
    }
    sampled_values = frame;
}

Dictionary PositionReplicator::get_sampled_values() const {
    return sampled_values.duplicate(true);
}

Vector3 PositionReplicator::get_sampled_position() const {
    return sampled_values.get(".:position", sampled_values.get(":position", Vector3()));
}

void PositionReplicator::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_property_paths", "paths"),
                         &PositionReplicator::set_property_paths);
    ClassDB::bind_method(D_METHOD("get_property_paths"), &PositionReplicator::get_property_paths);
    ClassDB::bind_method(D_METHOD("get_sampled_values"), &PositionReplicator::get_sampled_values);
    ClassDB::bind_method(D_METHOD("get_sampled_position"), &PositionReplicator::get_sampled_position);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "property_paths", PROPERTY_HINT_ARRAY_TYPE, "NodePath"),
                 "set_property_paths", "get_property_paths");
}
