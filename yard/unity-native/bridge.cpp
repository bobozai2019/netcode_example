#include "lobby.hpp"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>

using namespace netcode;

namespace {

struct Frame {
    std::uint64_t round, room;
    std::int32_t status, phase, host, ready, rejected, loss;
    std::uint32_t player, car, tick, seats, objects;
};

struct ObjectInfo { std::uint32_t id, schema, owner, revision, local_state; };
struct FieldInfo { const char* path; const char* property; std::int32_t transform; };

struct Yard {
    explicit Yard(yard::Options options) : lobby(std::move(options)) {}
    yard::Lobby lobby;
    std::vector<ObjectId> ids;
    std::string text;
};

thread_local std::string error;

template <typename Work>
int result(Work work) noexcept
{
    try { return work(); }
    catch (const std::exception& failure) { error = failure.what(); }
    catch (...) { error = "Unexpected native Unity yard error"; }
    return -1;
}

}

#define UNITY_API extern "C" __declspec(dllexport)

UNITY_API const char* ny_error() noexcept { return error.c_str(); }

UNITY_API Yard* ny_create(int count, const char* const* args, const char* assets) noexcept
{
    std::unique_ptr<Yard> instance;
    result([&] {
        std::vector<std::string> strings{"netcode-unity"};
        for (int i = 0; i < count; ++i) strings.emplace_back(args[i]);
        std::vector<char*> argv;
        for (auto& entry : strings) argv.push_back(entry.data());
        auto options = yard::parse_options(static_cast<int>(argv.size()), argv.data());
        options.assets = std::filesystem::u8path(assets);
        instance = std::make_unique<Yard>(std::move(options));
        return 0;
    });
    return instance.release();
}

UNITY_API void ny_destroy(Yard* yard) noexcept { delete yard; }

UNITY_API int ny_advance(Yard* yard, Frame* frame) noexcept
{
    return result([&] {
        auto* runner = yard->lobby.runner();
        if (!runner) {
            yard->ids.clear();
            *frame = {};
            frame->status = frame->phase = -1;
            return 0;
        }
        runner->update(Clock::now());
        const auto& match = runner->match();
        const auto round = match.round();
        if (round) yard->ids = match.objects();
        else yard->ids.clear();
        *frame = {round, match.room(), runner->status(), static_cast<int>(match.phase()), runner->options().host, match.ready(),
                  static_cast<int>(match.rejected()), static_cast<int>(match.loss()), match.player(),
                  match.car(), match.tick(), static_cast<std::uint32_t>(match.seats()),
                  static_cast<std::uint32_t>(yard->ids.size())};
        return 0;
    });
}

UNITY_API const char* ny_notice(Yard* yard) noexcept
{
    const auto* runner = yard->lobby.runner();
    return runner ? runner->match().notice().c_str() : "";
}

UNITY_API const char* ny_local_ip(Yard* yard) noexcept { return yard->lobby.local_ip().c_str(); }

UNITY_API const char* ny_room_text(Yard* yard, int kind, std::uint32_t index) noexcept
{
    const auto* runner = yard->lobby.runner();
    if (!runner) return "";
    if (result([&] {
        const auto& match = runner->match();
        const auto& messages = match.messages();
        if (kind == 0) yard->text = yard->lobby.endpoint();
        else if (kind == 1) yard->text = yard::connection_status(match);
        else if (index < messages.size()) {
            const auto& message = messages[index];
            yard->text = yard::player_name(message.sender) + ": " + message.text;
        } else yard->text.clear();
        return 0;
    }) < 0) return "";
    return yard->text.c_str();
}

UNITY_API int ny_players(Yard* yard, std::uint32_t* values) noexcept
{
    return result([&] {
        const auto* runner = yard->lobby.runner();
        if (!runner) return 0;
        const auto players = runner->match().players();
        std::copy(players.begin(), players.end(), values);
        return static_cast<int>(players.size());
    });
}

UNITY_API int ny_ports(std::uint32_t* values) noexcept
{
    return result([&] {
        const auto ports = yard::available_ports();
        std::copy(ports.begin(), ports.end(), values);
        return static_cast<int>(ports.size());
    });
}

UNITY_API int ny_enter(Yard* yard, int host, const char* address, const char* port) noexcept
{
    return result([&] { yard->lobby.enter(host != 0, address, port); return 1; });
}

UNITY_API int ny_leave(Yard* yard) noexcept
{
    return result([&] { yard->lobby.leave(); return 1; });
}

UNITY_API int ny_chat(Yard* yard, const char* text) noexcept
{
    return result([&]() -> int {
        auto* runner = yard->lobby.runner();
        return runner && runner->match().chat(text);
    });
}

UNITY_API int ny_kick(Yard* yard, std::uint32_t player) noexcept
{
    return result([&]() -> int {
        auto* runner = yard->lobby.runner();
        return runner && runner->match().kick(player);
    });
}

UNITY_API int ny_object(Yard* yard, std::uint32_t index, ObjectInfo* info, float* values, int capacity) noexcept
{
    return result([&] {
        const auto id = yard->ids.at(index);
        auto& match = yard->lobby.runner()->match();
        const auto object = match.presentation(id);
        const int count = static_cast<int>(object.values.size());
        if (capacity < count) throw std::length_error("Unity snapshot buffer is too small");
        *info = {object.id, object.schema, object.owner, object.revision, match.uses_local_state(id)};
        for (int i = 0; i < count; ++i) {
            if (const auto* number = std::get_if<float>(&object.values[i])) values[i] = *number;
            else if (const auto* flag = std::get_if<bool>(&object.values[i])) values[i] = *flag ? 1.f : 0.f;
            else throw std::invalid_argument("Use the typed object reader for this schema");
        }
        return count;
    });
}

UNITY_API int ny_object_data(Yard* yard, std::uint32_t index, ObjectInfo* info, int* mode,
                            float* public_x, std::uint8_t* data, int capacity) noexcept
{
    return result([&] {
        const auto id = yard->ids.at(index);
        auto& match = yard->lobby.runner()->match();
        const auto object = match.presentation(id);
        *info = {id, object.schema, object.owner, object.revision, match.uses_local_state(id)};
        *mode = match.predicts(id) ? 2 : match.buffered(id) ? 1 : 0;
        *public_x = object.schema == yard::Car ? std::get<float>(match.object(id)->values[0]) : 0.f;
        Writer out;
        out.u8(static_cast<std::uint8_t>(object.values.size()));
        for (const auto& field : object.values) {
            out.u8(static_cast<std::uint8_t>(field.index()));
            write_value(out, field);
        }
        if (capacity < 0 || out.bytes().size() > static_cast<std::size_t>(capacity))
            throw std::length_error("Unity typed snapshot exceeds buffer capacity");
        std::copy(out.bytes().begin(), out.bytes().end(), data);
        return static_cast<int>(out.bytes().size());
    });
}

UNITY_API int ny_binding(Yard* yard, std::uint32_t schema, std::uint32_t index, FieldInfo* field) noexcept
{
    return result([&] {
        const auto& fields = yard->lobby.layout().bindings(static_cast<SchemaId>(schema));
        if (index >= fields.size()) return 0;
        const auto& binding = fields[index];
        *field = {binding.path.c_str(), binding.property.c_str(), binding.transform};
        return 1;
    });
}

UNITY_API void ny_drive(Yard* yard, float throttle, float steer) noexcept
{
    if (auto* runner = yard->lobby.runner()) runner->match().set_input({throttle, steer});
}

UNITY_API int ny_act(Yard* yard, int action) noexcept
{
    return result([&]() -> int {
        auto* runner = yard->lobby.runner();
        if (!runner) return 0;
        auto& match = runner->match();
        switch (action) {
        case 1: return match.start();
        case 2: return match.open_gate();
        case 3: return match.barrier(true);
        case 4: return match.barrier(false);
        case 5: return match.horn();
        case 6: match.end_round(); break;
        case 7: match.end_room(); break;
        case 8: match.disconnect(); break;
        case 9: runner->rejoin(); break;
        case 10: return match.toggle_guest_authority(1);
        case 11: return match.toggle_guest_authority(2);
        case 12: return match.toggle_guest_authority(3);
        case 13: return match.cycle_driver();
        default: throw std::invalid_argument("Unknown Unity yard action");
        }
        return 1;
    });
}
