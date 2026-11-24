#pragma once

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <vector>

namespace godot {

class PositionReplicator : public Node {
    GDCLASS(PositionReplicator, Node)

    struct Binding {
        NodePath path;            // 完整配置，例如 Headlight:visible。
        NodePath relative_node;   // 相对于 Vehicle 的节点路径。
        StringName property;      // 在该节点上读取的属性名。
    };

    Node3D *root = nullptr;
    std::vector<Binding> bindings;
    Dictionary sampled_values;

protected:
    static void _bind_methods();

public:
    PositionReplicator();
    void set_property_paths(const TypedArray<NodePath> &paths);
    TypedArray<NodePath> get_property_paths() const;
    Dictionary get_sampled_values() const;
    Vector3 get_sampled_position() const;
    void _enter_tree() override;
    void _exit_tree() override;
    void _physics_process(double delta) override;
};

} // namespace godot
