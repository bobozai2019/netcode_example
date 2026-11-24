#include "field_value.hpp"
#include "bridge.hpp"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>

#include <sstream>
#include <type_traits>

using namespace godot;

using netcode_godot::field_value;


void NetcodeYard::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("configure", "arguments", "config"), &NetcodeYard::configure);
    ClassDB::bind_method(D_METHOD("settings"), &NetcodeYard::settings);
    ClassDB::bind_method(D_METHOD("bindings"), &NetcodeYard::bindings);
    ClassDB::bind_method(D_METHOD("advance"), &NetcodeYard::advance);
    ClassDB::bind_method(D_METHOD("drive", "throttle", "steer"), &NetcodeYard::drive);
    ClassDB::bind_method(D_METHOD("act", "action"), &NetcodeYard::act);
    ClassDB::bind_method(D_METHOD("ports"), &NetcodeYard::ports);
    ClassDB::bind_method(D_METHOD("enter", "host", "address", "port"), &NetcodeYard::enter);
    ClassDB::bind_method(D_METHOD("leave"), &NetcodeYard::leave);
    ClassDB::bind_method(D_METHOD("chat", "text"), &NetcodeYard::chat);
    ClassDB::bind_method(D_METHOD("kick", "player"), &NetcodeYard::kick);
}

String NetcodeYard::configure(const PackedStringArray& arguments, const String& config)
{
    if (!settings_.is_empty()) return "NetcodeYard has already been configured";
    try {
        std::vector<std::string> args{"netcode-godot"};
        for (int64_t i = 0; i < arguments.size(); ++i) {
            if (arguments[i] == "--assets") return "--assets is set by the Godot project";
            args.emplace_back(arguments[i].utf8().get_data());
        }
        std::vector<char*> argv;
        for (auto& arg : args) argv.push_back(arg.data());
        const auto options = yard::parse_options(static_cast<int>(argv.size()), argv.data());
        std::istringstream input(config.utf8().get_data());
        yard::Layout layout(input);
        Dictionary descriptions;
        for (const auto& [schema, definition] : layout.schemas().all()) {
            Array fields;
            for (const auto& binding : layout.bindings(schema)) {
                Dictionary field;
                field["id"] = binding.field.id;
                field["path"] = String::utf8(binding.path.c_str());
                field["property"] = String::utf8(binding.property.c_str());
                field["transform"] = binding.transform;
                fields.push_back(field);
            }
            descriptions[static_cast<int>(schema)] = fields;
        }
        lobby_ = std::make_unique<yard::Lobby>(options, std::move(layout));
        bindings_ = descriptions;
        settings_["host"] = options.host;
        settings_["smoke"] = options.smoke;
        settings_["binding_smoke"] = options.binding_smoke;
        settings_["trace"] = options.trace;
        settings_["scripted"] = options.scenario != yard::Scenario::None;
        settings_["capture"] = String(options.capture.c_str());
        settings_["lobby_capture"] = String(options.lobby_capture.c_str());
        settings_["local_ip"] = String::utf8(lobby_->local_ip().c_str());
        return {};
    } catch (const std::exception& error) {
        return String::utf8(error.what());
    }
}

Dictionary NetcodeYard::advance()
{
    Dictionary frame;
    auto* runner = lobby_ ? lobby_->runner() : nullptr;
    if (!runner) {
        frame["phase"] = -1;
        return frame;
    }
    try {
        runner->update(netcode::Clock::now());
        auto& match = runner->match();
        frame["status"] = runner->status();
        frame["host"] = runner->options().host;
        frame["phase"] = static_cast<int>(match.phase());
        frame["round"] = static_cast<int64_t>(match.round());
        frame["player"] = match.player();
        frame["car"] = match.car();
        frame["tick"] = match.tick();
        frame["seats"] = static_cast<int>(match.seats());
        frame["ready"] = match.ready();
        frame["reject"] = static_cast<int>(match.rejected());
        frame["loss"] = static_cast<int>(match.loss());
        frame["notice"] = String::utf8(match.notice().c_str());
        if (match.phase() != netcode::RoomPhase::Playing) {
            frame["endpoint"] = String::utf8(lobby_->endpoint().c_str());
            frame["room"] = String::utf8(std::to_string(match.room()).c_str());
            if (match.phase() == netcode::RoomPhase::Ended) {
                frame["connection_status"] = String::utf8(yard::connection_status(match).c_str());
            }
            Array players;
            for (const auto id : match.players()) players.push_back(id);
            frame["players"] = players;
            PackedStringArray chat;
            for (const auto& message : match.messages()) {
                chat.push_back(String::utf8((yard::player_name(message.sender) + ": " + message.text).c_str()));
            }
            frame["chat"] = chat;
        }
        Array objects;
        for (const auto id : match.objects()) {
            const auto object = match.presentation(id);
            Dictionary snapshot;
            snapshot["id"] = object.id;
            snapshot["schema"] = object.schema;
            snapshot["owner"] = object.owner;
            snapshot["revision"] = object.revision;
            snapshot["local_state"] = match.uses_local_state(id);
            snapshot["predicted"] = match.predicts(id);
            snapshot["buffered"] = match.buffered(id);
            if (object.schema == yard::Car) snapshot["public_x"] = std::get<float>(match.object(id)->values[0]);
            Array values;
            for (const auto& value : object.values) values.push_back(field_value(value));
            snapshot["values"] = values;
            objects.push_back(snapshot);
        }
        frame["objects"] = objects;
    } catch (const std::exception& error) {
        frame["error"] = String::utf8(error.what());
    }
    return frame;
}

void NetcodeYard::drive(double throttle, double steer)
{
    if (auto* runner = lobby_->runner()) runner->match().set_input({static_cast<float>(throttle), static_cast<float>(steer)});
}

bool NetcodeYard::act(const String& action)
{
    auto* runner = lobby_->runner();
    if (!runner) return false;
    auto& match = runner->match();
    if (action == "start") return match.start();
    if (action == "gate") return match.open_gate();
    if (action == "place") return match.barrier(true);
    if (action == "remove") return match.barrier(false);
    if (action == "horn") return match.horn();
    if (action == "authority_1") return match.toggle_guest_authority(1);
    if (action == "authority_2") return match.toggle_guest_authority(2);
    if (action == "authority_3") return match.toggle_guest_authority(3);
    if (action == "cycle_driver") return match.cycle_driver();
    if (action == "end_round") match.end_round();
    else if (action == "end_room") match.end_room();
    else if (action == "disconnect") match.disconnect();
    else if (action == "rejoin") runner->rejoin();
    else return false;
    return true;
}

PackedStringArray NetcodeYard::ports() const
{
    PackedStringArray result;
    for (const auto port : yard::available_ports()) result.push_back(String::num_int64(port));
    return result;
}

String NetcodeYard::enter(bool host, const String& address, const String& port)
{
    try {
        lobby_->enter(host, address.utf8().get_data(), port.utf8().get_data());
        return {};
    } catch (const std::exception& error) {
        return String::utf8(error.what());
    }
}

void NetcodeYard::leave() { lobby_->leave(); }
bool NetcodeYard::chat(const String& text)
{
    auto* runner = lobby_->runner();
    return runner && runner->match().chat(text.utf8().get_data());
}
bool NetcodeYard::kick(int64_t player)
{
    auto* runner = lobby_->runner();
    return runner && runner->match().kick(static_cast<netcode::PlayerId>(player));
}
