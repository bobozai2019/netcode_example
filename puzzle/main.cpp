#include "session/game_session.hpp"

#include <cmath>
#include <iostream>
#include <mutex>
#include <sstream>
#include <thread>

namespace {

using namespace netcode;
using namespace std::chrono_literals;

constexpr RoomId room_id = 410;
constexpr ObjectId x = 1, y = 2;
constexpr SchemaId piece = 1, marker = 2, scoreboard = 3;

SessionOptions options(bool host, bool spectator)
{
    SessionOptions result;
    result.room = room_id;
    result.host = host;
    result.spectator = spectator;
    result.extended_join = true;
    result.admission = {5, true, true};
    return result;
}

bool message(const Bytes& data, GameMessage type)
{
    return !data.empty() && data[0] == static_cast<std::uint8_t>(type);
}

bool integer_field(const Value& value, float low, float high)
{
    const auto n = std::get<float>(value);
    return n >= low && n <= high && n == std::trunc(n);
}

class Puzzle {
public:
    Puzzle(std::unique_ptr<Transport> link, bool host, bool spectator)
        : link_(std::make_unique<GateLink>(std::move(link))), game_(*link_, options(host, spectator))
    {
        game_.on_grant = [](const ObjectGrant& g) {
            std::cout << "grant object=" << g.object << " writer=" << g.writer << " epoch=" << g.epoch
                      << " step=" << g.sample.source_step << std::endl;
        };
        game_.on_snapshot = [this](const AppliedSnapshot& result) {
            for (const auto id : result.ready)
                std::cout << "ready object=" << id << " scene=" << object(id)->scene << std::endl;
        };
        game_.schemas().add({piece, 1, {{10, FieldType::Float}, {20, FieldType::Float}, {30, FieldType::Flag}}});
        game_.schemas().add({marker, 1, {{10, FieldType::Float}}});
        game_.schemas().add({scoreboard, 1, {{10, FieldType::Int}, {20, FieldType::String, 48}}});
        game_.writers().register_model(piece, 1, {10, 20}, 0,
            [](const Object&, const AuthoritySample&, const AuthoritySample& next, Tick) {
                return integer_field(next.values[0], 0, 15) && integer_field(next.values[1], 0, 3);
            });
        game_.writers().register_model(marker, 1, {10}, 0,
            [](const Object&, const AuthoritySample&, const AuthoritySample& next, Tick) {
                return integer_field(next.values[0], 0, 15);
            });
        game_.writers().allow_requests(piece, {});
        game_.writers().allow_requests(marker, {ClaimMode::Dynamic, 3});
        game_.writers().on_request([this](const Claim& c) {
            requests_[c.object] = c;
            std::cout << "request object=" << c.object << " requester=" << c.requester << std::endl;
        });
        game_.writers().on_result([](const Claim& c, ClaimStatus status) {
            std::cout << "claim_result object=" << c.object << " sequence=" << c.sequence
                      << " status=" << static_cast<unsigned>(status) << std::endl;
        });
    }

    void update()
    {
        const auto now = Clock::now();
        for (auto& event : link_->poll(now)) {
            if (hold_down_ && event.type == EventType::Message &&
                (message(event.payload, GameMessage::Snapshot) || message(event.payload, GameMessage::CompactSnapshot) || message(event.payload, GameMessage::AuthorityAck))) {
                held_down_[event.payload.front()] = std::move(event);
                continue;
            }
            receive(event);
        }
        game_.flush(now);
    }

    void command(const std::string& line)
    {
        std::istringstream in(line);
        std::string verb;
        in >> verb;
        ObjectId id = 0;
        PlayerId writer = 0;
        float cell = 0, facing = 0;
        bool ok = false;
        if (verb == "start" && game_.host() && game_.host()->members().size() >= 2 && game_.start(Clock::now())) {
            game_.authority().create(x, piece, 2, {2.f, 0.f, false}, game_.tick());
            game_.authority().create(y, marker, 3, {1.f}, game_.tick());
            ok = true;
        } else if (verb == "scene" && game_.host() && round()) {
            ok = game_.authority().create(3, scoreboard, host_player, {std::int32_t(16777217), std::string("North")}, game_.tick(), 20, {y});
        } else if (verb == "scope" && game_.host()) {
            PlayerId player;
            SceneId scene;
            if (in >> player >> scene) {
                const auto member = game_.host()->members().find(player);
                std::set<ObjectId> ids;
                while (in >> id) ids.insert(id);
                if (member != game_.host()->members().end())
                    ok = game_.authority().set_interest(member->second.peer, scene, ids.empty() ? std::nullopt : std::optional{ids});
            }
        } else if (verb == "classify" && game_.host()) {
            std::string group;
            std::uint64_t key;
            std::uint16_t divisor;
            if (in >> id >> group >> key >> divisor && (group == "area" || group == "user"))
                ok = game_.authority().set_distribution(id, {group == "area" ? InterestKind::Area : InterestKind::User, key, divisor});
        } else if (verb == "subscribe" && game_.host()) {
            std::string group;
            if (in >> writer >> group && (group == "area" || group == "user")) {
                const auto member = game_.host()->members().find(writer);
                std::set<std::uint64_t> keys;
                std::uint64_t key;
                while (in >> key) keys.insert(key);
                if (member != game_.host()->members().end())
                    ok = game_.authority().subscribe(member->second.peer, group == "area" ? InterestKind::Area : InterestKind::User, std::move(keys));
            }
        } else if (verb == "clock") {
            const auto& clock = game_.clock();
            std::cout << "clock synced=" << clock.synchronized() << " ms=" << std::llround(clock.seconds() * 1000)
                      << " rtt_us=" << std::llround(clock.rtt() * 1000000) << std::endl;
            return;
        } else if (verb == "award" && game_.host()) {
            ok = game_.authority().capture(3, {std::int32_t(16777219), std::string("South")}, game_.tick());
        } else if (verb == "retire" && game_.host()) {
            ok = game_.authority().destroy(3, game_.tick());
            if (ok) game_.writers().forget(3);
        } else if ((verb == "loading" || verb == "loaded") && game_.guest()) {
            SceneId scene;
            if (in >> scene && scene) {
                game_.scene_ready(scene, verb == "loaded");
                ok = true;
            }
        } else if (verb == "visible" && in >> id) {
            const auto* o = object(id);
            std::cout << "visible object=" << id << " present=" << bool(o);
            if (o && o->schema == scoreboard) std::cout << " scene=" << o->scene << " score=" << std::get<std::int32_t>(o->values[0])
                << " name=" << std::get<std::string>(o->values[1]);
            std::cout << std::endl;
            return;
        } else if (verb == "grant" && in >> id >> writer) {
            ok = game_.writers().assign(id, writer, game_.tick());
        } else if (verb == "claim" && in >> id) {
            ok = game_.writers().request(id);
        } else if (verb == "drop" && in >> id) {
            ok = game_.writers().release(id);
        } else if ((verb == "allow" || verb == "deny") && in >> id && requests_.count(id)) {
            ok = game_.writers().answer(requests_.at(id), verb == "allow", game_.tick());
            requests_.erase(id);
        } else if (verb == "move" && in >> id >> cell && object(id)) {
            Values values{cell};
            if (id == x && in >> facing) values.push_back(facing);
            if (const auto* grant = game_.writers().grant(id))
                ok = game_.writers().submit(id, grant->epoch, 0, std::move(values));
        } else if (verb == "protect" && game_.host() && object(x)) {
            auto values = object(x)->values;
            values[2] = true;
            ok = game_.authority().capture(x, values, game_.tick());
        } else if (verb == "mute") {
            hold_down_ = true;
            ok = true;
        } else if (verb == "unmute") {
            hold_down_ = false;
            for (const auto& [type, event] : held_down_) receive(event);
            held_down_.clear();
            ok = true;
        } else if (verb == "hold" && game_.guest()) {
            ok = true;
            link_->hold = true;
        } else if (verb == "release" && game_.guest()) {
            ok = link_->release();
        } else if (verb == "show" && in >> id && (id == x || id == y) && object(id)) {
            const auto& canonical = *object(id);
            const auto current = game_.writers().presentation(canonical);
            const auto* grant = game_.writers().grant(id);
            std::cout << "view object=" << id << " writer=" << game_.writers().writer(id)
                      << " epoch=" << (grant ? grant->epoch : 0)
                      << " confirmed=" << (grant ? grant->confirmed : 0)
                      << " public=" << std::get<float>(canonical.values[0])
                      << " cell=" << std::get<float>(current.values[0]);
            if (id == x) std::cout << " facing=" << std::get<float>(current.values[1])
                                   << " protected=" << std::get<bool>(canonical.values[2]);
            std::cout << std::endl;
            return;
        } else if (verb == "end" && game_.host()) {
            game_.end(Clock::now());
            ok = true;
        } else if (verb == "status") {
            if (game_.host()) std::cout << "seats=" << game_.host()->members().size();
            else std::cout << "player=" << game_.guest()->ticket().player << " watching=" << game_.guest()->spectator()
                           << " rejected=" << static_cast<unsigned>(game_.guest()->rejected());
            std::cout << " round=" << round() << " ended="
                      << (game_.host() ? game_.host()->phase() == RoomPhase::Ended : game_.guest()->phase() == RoomPhase::Ended)
                      << std::endl;
            return;
        } else if (verb == "traffic") {
            const auto t = link_->traffic();
            std::cout << "traffic tcp_tx=" << t.tcp_sent << " tcp_rx=" << t.tcp_received
                      << " udp_tx=" << t.udp_sent << " udp_rx=" << t.udp_received << std::endl;
            return;
        }
        std::cout << verb << (ok ? " ok" : " unavailable") << std::endl;
    }

private:
    class GateLink final : public Transport {
    public:
        explicit GateLink(std::unique_ptr<Transport> link) : link_(std::move(link)) {}
        std::vector<Event> poll(TimePoint now) override { return link_->poll(now); }
        bool send(Peer peer, Lane lane, const Bytes& data) override
        {
            if (hold && message(data, GameMessage::AuthorityState)) {
                delayed_ = Event{EventType::Message, peer, lane, data};
                return true;
            }
            return link_->send(peer, lane, data);
        }
        void close(Peer peer) override { link_->close(peer); }
        Traffic traffic() const override { return link_->traffic(); }
        bool release()
        {
            if (!delayed_) return false;
            hold = false;
            const auto event = std::move(*delayed_);
            delayed_.reset();
            return send(event.peer, event.lane, event.payload);
        }
        bool hold = false;
    private:
        std::unique_ptr<Transport> link_;
        std::optional<Event> delayed_;
    };

    RoundId round() const { return game_.round(); }
    const Object* object(ObjectId id) const { return game_.object(id); }

    void receive(const Event& event)
    {
        if (game_.host() && event.type == EventType::Message && event.lane == Lane::Game &&
            message(event.payload, GameMessage::AuthorityState)) {
            Reader in(event.payload);
            GameMessage type;
            ObjectId id;
            std::uint32_t epoch;
            if (read_game_header(in, type, room_id, round()) && in.u32(id) && in.u32(epoch)) {
                if (const auto* g = game_.writers().grant(id); g && epoch < g->epoch)
                    std::cout << "old_state object=" << id << " epoch=" << epoch << std::endl;
            }
        }
        game_.receive(event, Clock::now());
    }

    std::unique_ptr<GateLink> link_;
    GameSession game_;
    std::map<ObjectId, Claim> requests_;
    bool hold_down_ = false;
    std::map<std::uint8_t, Event> held_down_;
};

}

int main(int argc, char** argv)
{
    if (argc != 3 || (std::string_view(argv[1]) != "host" && std::string_view(argv[1]) != "join" && std::string_view(argv[1]) != "watch")) return 2;
    try {
        const auto port = std::stoul(argv[2]);
        if (!port || port > 65535) return 2;
        const bool host = std::string_view(argv[1]) == "host";
        const DirectConfig config{"127.0.0.1", static_cast<std::uint16_t>(port)};
        Puzzle puzzle(host ? listen_direct(config) : connect_direct(config), host, std::string_view(argv[1]) == "watch");
        std::mutex mutex;
        std::deque<std::string> pending;
        std::thread input([&] {
            std::string line;
            while (std::getline(std::cin, line) && line != "quit") {
                std::lock_guard lock(mutex);
                pending.push_back(line);
            }
            std::lock_guard lock(mutex);
            pending.push_back("quit");
        });
        std::cout << (host ? "listening" : "joining") << " port=" << port << std::endl;
        try {
            for (;;) {
                puzzle.update();
                std::deque<std::string> commands;
                {
                    std::lock_guard lock(mutex);
                    commands.swap(pending);
                }
                for (const auto& command : commands) {
                    if (command == "quit") {
                        input.join();
                        return 0;
                    }
                    puzzle.command(command);
                }
                std::this_thread::sleep_for(5ms);
            }
        } catch (...) {
            // The standard input reader may be blocked when networking fails.
            std::terminate();
        }
    } catch (const std::exception& error) {
        std::cerr << error.what() << std::endl;
        return 1;
    }
}
