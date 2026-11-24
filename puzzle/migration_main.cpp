#include "session/migration.hpp"
#include <iostream>
#include <thread>

using namespace netcode;
using namespace std::chrono_literals;
namespace {
void register_motion(GameSession& game) {
    const bool piece =
        game.prediction().register_model(2, {1, 1, {0}, [](Values& v, const Bytes& input, Tick) {
                                                 std::get<int32_t>(v[0]) += input[0];
                                                 return true;
                                             }});
    const bool platform =
        game.prediction().register_model(3, {1, 1, {0}, [](Values& v, const Bytes& input, Tick) {
                                                 auto& speed = std::get<float>(v[1]);
                                                 speed = input[0] * .25f;
                                                 std::get<float>(v[0]) += speed;
                                                 return true;
                                             }});
    if (!piece || !platform)
        throw std::runtime_error("motion models could not be registered");
}
bool motion_at(GameSession& game, int cell, float height) {
    const auto* piece = game.object(3);
    const auto* platform = game.object(4);
    return piece && platform && std::get<int32_t>(piece->values[0]) == cell &&
           std::get<float>(platform->values[0]) == height;
}
}
int main(int argc, char** argv) try {
    const bool chain = argc == 5 && std::string_view(argv[4]) == "--chain";
    if (argc != 4 && !chain)
        return 2;
    bool first = std::string(argv[1]) == "host";
    auto port = std::stoi(argv[2]), standby = std::stoi(argv[3]);
    if (port < 1 || port > 65535 || standby < 1 || standby >= 65534)
        return 2;
    DirectConfig dest{"127.0.0.1", uint16_t(port)};
    SessionOptions opts;
    opts.room = 550;
    opts.host = first;
    opts.extended_join = true;
    opts.admission = {4, true, true};
    Schemas schemas;
    schemas.add({1, 1, {{1, FieldType::Int}, {2, FieldType::String, 50}}});
    schemas.add({2, 1, {{1, FieldType::Int}}});
    schemas.add({3, 1, {{1, FieldType::Float}, {2, FieldType::Float}}});
    MigrationOptions settings;
    settings.standbys[2] = {"127.0.0.1", uint16_t(standby)};
    if (chain) settings.standbys[3] = {"127.0.0.1", uint16_t(standby+2)};
    auto open = [](bool listen, const StandbyEndpoint& e) {
        DirectConfig config{e.address, e.port};
        return listen ? listen_direct(config) : connect_direct(config);
    };
    const LanDiscoveryOptions directory_options{"127.0.0.1", uint16_t(standby + 1)};
    auto browser = lan_directory(directory_options);
    bool saw_primary_endpoint = false, saw_successor_endpoint = false;
    MigratingSession run(first ? listen_direct(dest) : connect_direct(dest), opts, schemas, settings, open,
                         [&](GameSession& g) {
                             if (g.host()) {
                                 RoomListing listing;
                                 listing.name = "Hall";
                                 listing.region = "local";
                                 listing.build = "migration";
                                 listing.port = g.coordinator() == 1 ? uint16_t(port) : settings.standbys.at(g.coordinator()).port;
                                 if (!g.advertise(lan_directory(directory_options), listing))
                                     throw std::runtime_error("cannot list the coordinator");
                             }
                             register_motion(g);
                             g.writers().register_model(1, 1, {1}, 0);
                             g.writers().allow_requests(1, {ClaimMode::Dynamic, 0});
                         });
    unsigned piece_term = 0, platform_term = 0;
    int last_phase = -1;
    bool initialized = false, assigned = false, wrote = false, restored = false, followed = false,
         submitted = false, stable = false;
    TimePoint next_trace{}, handoff_after{};
    bool passed_second = false;
    Tick announce = 0;
    int32_t last_value = -1;
    PlayerId prior_local = 0;
    auto deadline = Clock::now() + 45s;
    std::cout << "migration_open host=" << first << std::endl;
    while (Clock::now() < deadline) {
        auto now = Clock::now();
        run.pump(now);
        browser->poll(now);
        for (const auto& listing : browser->search({"local", "migration"})) {
            if (listing.room != opts.room || listing.endpoint != "127.0.0.1")
                continue;
            saw_primary_endpoint |= listing.port == port;
            saw_successor_endpoint |= listing.port == standby;
        }
        auto* g = run.active();
        if (int(run.phase()) != last_phase) {
            last_phase = int(run.phase());
            std::cout << "migration_phase value=" << last_phase << std::endl;
        }
        if (!g) {
            if (chain && passed_second && run.phase() == MigrationPhase::Ended)
                return 0;
            std::this_thread::sleep_for(5ms);
            continue;
        }
        auto local = g->local();
        if (local != prior_local) {
            std::cout << "migration_member player=" << local << std::endl;
            prior_local = local;
        }
        if (first && !initialized && g->host()->members().size() == 3 && g->start(now)) {
            g->world().load_map(7, "hall");
            g->world().spawn(1, 1, {int32_t(11), std::string("door")}, {7, 700});
            g->world().spawn(1, 3, {int32_t(0), std::string("key")}, {7, 701, 1});
            const auto piece = g->world().spawn(2, 3, {int32_t(0)}, {7, 702});
            const auto platform = g->world().spawn(3, 3, {0.f, 0.f}, {7, 703});
            if (!g->prediction().bind(piece, 3) || !g->prediction().bind(platform, 3))
                throw std::runtime_error("could not bind predicted objects");
            initialized = true;
        }
        if (g->guest() && g->world().maps().count(7) && !g->object(2))
            g->world().loaded(7, g->world().maps().at(7).generation);
        if (first && !assigned && g->round())
            assigned = g->writers().assign(2, 3, g->tick());
        if (local == 3 && (g->term() == 1 || followed)) {
            auto& models = g->prediction();
            const unsigned term = g->term();
            if (piece_term < term && models.confirmed(3) == term - 1 &&
                models.advance(3, Bytes{uint8_t(term == 1 ? 3 : 4)}))
                piece_term = term;
            if (platform_term < term && models.confirmed(4) == term - 1 &&
                models.advance(4, Bytes{uint8_t(term == 1 ? 4 : 8)}))
                platform_term = term;
        }
        auto* obj = g->object(2);
        if (obj && g->term() == 1 && local == 3 && !wrote && g->writers().writer(2) == 3) {
            auto grant = g->writers().grant(2);
            wrote = g->writers().submit(2, grant->epoch, 0, {int32_t(77)});
        }
        if (obj && std::get<int32_t>(obj->values[0]) != last_value) {
            last_value = std::get<int32_t>(obj->values[0]);
            std::cout << "migration_value player=" << local << " term=" << g->term()
                      << " value=" << last_value << std::endl;
        }
        if (local == 2 && g->term() == 1 && obj && last_value == 77 && run.saved_tick() &&
            motion_at(*g, 3, 1.f) && !stable) {
            if (!announce)
                announce = run.saved_tick();
            if (run.saved_tick() > announce + 6) {
                stable = true;
                std::cout << "standby_current tick=" << run.saved_tick() << std::endl;
            }
        }
        if (g->term() == 2 && now >= next_trace) {
            next_trace = now + 2s;
            std::cout << "recovery_state local=" << local << " round=" << g->round()
                      << " maps=" << g->world().maps().size() << " objects=" << g->objects().size()
                      << " writer=" << g->writers().writer(2)
                      << " resumed=" << (g->guest() && g->guest()->resumed()) << std::endl;
        }
        if (obj && g->term() == 2 && g->world().find(7, 701) == 2 && g->world().identity(2)->parent == 1 &&
            std::get<std::string>(obj->values[1]) == "key" && last_value == 77) {
            if (g->host() && local == 2 && !restored) {
                restored = true;
                std::cout << "migrated_host player=2 round=" << g->round()
                          << " writer=" << g->writers().writer(2) << std::endl;
            }
            if (g->guest() && local == 3 && g->guest()->resumed() && g->writers().writer(2) == 3) {
                if (!followed) {
                    followed = true;
                    std::cout << "migrated_guest player=3 epoch=" << g->writers().grant(2)->epoch
                              << std::endl;
                }
                if (!submitted)
                    submitted = g->writers().submit(2, g->writers().grant(2)->epoch, 0, {int32_t(88)});
            }
        }
        if (chain && g->host() && g->term() == 3 && local == 3) {
            auto live = g->object(2);
            if (!live || std::get<int32_t>(live->values[0]) != 89 || g->host()->members().size() != 1 ||
                !g->authority().capture(2,{int32_t(90),std::string("key")},g->tick()))
                throw std::runtime_error("last player failed to continue from final handoff image");
            std::cout << "handoff_pass player=3 term=3 restored=89 written=90" << std::endl;
            return 0;
        }
        if (chain && passed_second && local == 2 && now >= handoff_after && g->term() == 2) {
            if (!g->writers().assign(2,local,g->tick()) ||
                !g->authority().capture(2,{int32_t(89),std::string("key")},g->tick()) || !run.handoff())
                throw std::runtime_error("could not initiate two-player handoff");
            continue;
        }
        if (!passed_second && saw_primary_endpoint && saw_successor_endpoint && g->term() == 2 && last_value == 88 &&
            motion_at(*g, 7, 3.f) && g->prediction().confirmed(3) == 2 && g->prediction().confirmed(4) == 2 &&
            ((g->host() && restored) || (g->guest() && followed))) {
            if (!first && !stable)
                stable = true;
            std::cout << "migration_pass player=" << local << " term=2 round=" << g->round()
                      << " value=88 directory_port=" << standby
                      << " piece=7 height_mm=3000 piece_ack=" << g->prediction().confirmed(3)
                      << " platform_ack=" << g->prediction().confirmed(4) << std::endl;
            passed_second = true;
            handoff_after = now + 1s;
            if (chain) continue;
            // Keep the endpoint alive long enough for all survivors to receive the accepted state.
            for (int i = 0; i < 180; ++i) {
                run.pump(Clock::now());
                std::this_thread::sleep_for(5ms);
            }
            return 0;
        }
        std::this_thread::sleep_for(5ms);
    }
    return 1;
} catch (const std::exception& e) {
    std::cerr << e.what() << std::endl;
    return 1;
}
