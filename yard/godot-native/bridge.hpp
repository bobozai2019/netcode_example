#pragma once

#include "lobby.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

class NetcodeYard final : public godot::RefCounted {
    GDCLASS(NetcodeYard, godot::RefCounted)

public:
    godot::String configure(const godot::PackedStringArray& arguments, const godot::String& config);
    godot::Dictionary settings() const { return settings_; }
    godot::Dictionary bindings() const { return bindings_; }
    godot::Dictionary advance();
    void drive(double throttle, double steer);
    bool act(const godot::String& action);
    godot::PackedStringArray ports() const;
    godot::String enter(bool host, const godot::String& address, const godot::String& port);
    void leave();
    bool chat(const godot::String& text);
    bool kick(int64_t player);

protected:
    static void _bind_methods();

private:
    std::unique_ptr<yard::Lobby> lobby_;
    godot::Dictionary settings_, bindings_;
};
