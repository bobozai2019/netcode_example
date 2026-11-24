#include "match.hpp"
#include "transport/memory.hpp"

#include <cmath>
#include <iostream>
#include <stdexcept>

namespace {
using namespace netcode;
using namespace yard;
using namespace std::chrono_literals;
void check(bool value, const char* reason) { if (!value) throw std::runtime_error(reason); }

class Downlink final : public Transport {
public:
    MemoryTransport pipe;
    bool pause = false, allow_world = false, change_speed = false;
    unsigned checkpoints = 0, world_events = 0;
    bool touched = false;
    std::vector<Event> poll(TimePoint now) override
    {
        std::vector<Event> result;
        if (!pause) result.swap(held_);
        auto pass = [&](const Event& e) {
            if (!allow_world || e.payload.empty()) return false;
            const auto type = static_cast<GameMessage>(e.payload[0]);
            return type == GameMessage::CollisionWorld || type == GameMessage::RpcAck;
        };
        if (pause && allow_world) {
            for (auto it = held_.begin(); it != held_.end();) {
                if (!pass(*it)) { ++it; continue; }
                result.push_back(std::move(*it));
                it = held_.erase(it);
            }
        }
        for (auto& event : pipe.poll(now)) {
            const bool world = !event.payload.empty() && event.payload[0] == static_cast<unsigned>(GameMessage::CollisionWorld);
            if (world) ++world_events;
            if (pause && !pass(event)) held_.push_back(std::move(event));
            else result.push_back(std::move(event));
        }
        for (auto& event : result) {
            if (event.payload.empty() || event.payload[0] != static_cast<unsigned>(GameMessage::Checkpoint)) continue;
            ++checkpoints;
            if (!change_speed) continue;
            Reader in(event.payload);
            // Preserve room, round, object, epoch, tick, input ACK, frozen flag,
            // pose and scene bytes. Only the signed speed differs.
            Bytes header, tail;
            float speed;
            check(in.read(17 + 4 * 4 + 1, header) && in.f32(speed) && in.read(in.remaining(), tail), "checkpoint fixture");
            Writer altered;
            altered.append(header); altered.f32(-60.f); altered.append(tail);
            event.payload = altered.take();
            change_speed = false;
            touched = true;
        }
        return result;
    }
    bool send(Peer peer, Lane lane, const Bytes& data) override { return pipe.send(peer, lane, data); }
    void close(Peer peer) override { pipe.close(peer); }
    Traffic traffic() const override { return pipe.traffic(); }
private:
    std::vector<Event> held_;
};

class Pair {
public:
    explicit Pair(const Layout& layout, unsigned send_rate = 20) {
        auto a = std::make_unique<MemoryTransport>();
        auto b = std::make_unique<Downlink>();
        hub = a.get(); hub->link(b->pipe); down = b.get();
        const auto period = std::chrono::nanoseconds(1s) / send_rate;
        host = std::make_unique<Match>(layout, std::move(a), true, 511, std::nullopt, Match::Log{}, period);
        guest = std::make_unique<Match>(layout, std::move(b), false, 511, std::nullopt, Match::Log{}, period);
        advance(200);
        check(host->start(), "start prediction room");
        advance(600);
        check(guest->predicts(guest->car()) && host->state_writer(guest->car()) == host_player, "default host authority");
    }
    void advance(int ms) {
        while (ms-- > 0) { now += 1ms; host->update(now); guest->update(now); }
    }
    float shown() { return std::get<float>(guest->presentation(guest->car()).values[0]); }
    float public_x() const { return std::get<float>(guest->object(guest->car())->values[0]); }
    TimePoint now{};
    Downlink* down;
    MemoryTransport* hub;
    std::unique_ptr<Match> host, guest;
};
}

int main(int argc, char** argv)
{
    if (argc != 2) return 2;
    const Layout layout(argv[1]);
    Pair delayed(layout);
    const float initial = delayed.shown();
    delayed.down->pause = true;
    delayed.guest->set_input({1.f, 0.f});
    int first = 0;
    for (int ms = 1; ms <= 150; ++ms) {
        delayed.advance(1);
        if (!first && delayed.shown() > initial) first = ms;
    }
    check(first && first <= 34 && delayed.public_x() == initial && delayed.guest->local_prediction().pending().size() >= 4,
          "car waited for a host snapshot before moving");
    std::cout << "closed_downlink_ms=150 first_move_ms=" << first << " public_x=" << delayed.public_x()
              << " predicted_x=" << delayed.shown() << '\n';
    delayed.down->pause = false;
    delayed.advance(120);
    check(delayed.public_x() > initial, "host did not publish motion");

    Pair clean(layout), changed(layout);
    for (auto* pair : {&clean, &changed}) { pair->guest->set_input({.8f,-.2f}); pair->advance(420); }
    changed.down->change_speed = true;
    for (int ms = 0; ms < 100 && !changed.down->touched; ++ms) { clean.advance(1); changed.advance(1); }
    const auto& p = changed.guest->local_prediction();
    const auto replays = p.replayed();
    const auto count = changed.down->checkpoints;
    const auto difference = std::abs(changed.shown() - clean.shown());
    check(changed.down->touched && difference > .01f && changed.public_x() == clean.public_x() &&
          !p.pending().empty(), "speed-only perturbation did not distinguish the predicted paths");
    for (int ms = 0; ms < 100 && changed.down->checkpoints == count; ++ms) { clean.advance(1); changed.advance(1); }
    check(p.replayed() > replays && changed.shown() == clean.shown() &&
          p.state().speed == clean.guest->local_prediction().state().speed, "remaining inputs failed to restore reference trajectory");
    std::cout << "speed_only_error=" << difference << " after_replay_error=" << std::abs(changed.shown() - clean.shown())
              << " replayed=" << p.replayed() - replays << '\n';

    Pair barriers(layout);
    barriers.down->pause = true;
    check(barriers.guest->barrier(true), "place barrier");
    barriers.guest->set_input({1.f, 0.f});
    barriers.advance(950);
    const float before_world = barriers.shown();
    barriers.down->allow_world = true;
    barriers.advance(1);
    check(before_world - barriers.shown() > 20.f, "late world event did not replay the earlier obstacle");
    check(barriers.down->world_events && barriers.shown() > 260.f && barriers.shown() < 271.f && barriers.public_x() == 237.f,
          "prediction crossed a barrier before its public snapshot arrived");
    const float stopped = barriers.shown();
    check(barriers.guest->barrier(false) && barriers.guest->open_gate(), "remove barrier and open gate");
    barriers.advance(900);
    check(barriers.down->world_events >= 3 && barriers.shown() > 345.f, "historical gate or removed barrier kept blocking movement");
    barriers.down->pause = false; barriers.advance(200);
    std::cout << "collision_events=" << barriers.down->world_events << " before_world_x=" << before_world
              << " blocked_x=" << stopped << " cleared_x=" << barriers.shown() << '\n';

    for (unsigned rate : {10u, 40u}) {
        Pair pair(layout, rate);
        const auto& local = pair.guest->local_prediction();
        const auto issued = local.confirmed() + local.pending().size();
        const auto tick = pair.host->tick(), sent = pair.host->send_tick();
        pair.guest->set_input({-.5f, .1f});
        pair.advance(1000);
        check(local.confirmed() + local.pending().size() - issued == 30 && pair.host->tick() - tick == 30 &&
              pair.host->send_tick() - sent == rate && pair.host->tick() - local.checkpoint_tick() <= 3, "input history used packet clock");
        std::cout << "prediction_hz=" << rate << " client_steps=30 host_steps=30 packets=" << pair.host->send_tick() - sent << '\n';
    }

    Pair resume(layout);
    resume.guest->set_input({-.7f, .1f});
    resume.advance(540);
    resume.host->freeze(true);
    resume.advance(160);
    const auto ticket = resume.guest->ticket();
    const auto car = resume.guest->car();
    const auto speed = resume.guest->local_prediction().state().speed;
    check(speed < -10.f, "resume fixture had no reverse speed");
    resume.guest->disconnect();
    resume.advance(40);
    auto fresh = std::make_unique<Downlink>();
    resume.hub->link(fresh->pipe);
    resume.down = fresh.get();
    resume.guest = std::make_unique<Match>(layout, std::move(fresh), false, 511, ticket);
    resume.advance(300);
    check(resume.guest->predicts(car) && resume.guest->car() == car && resume.guest->player() == ticket.player &&
          resume.guest->local_prediction().state().speed == speed && resume.guest->local_prediction().pending().empty(),
          "resume lost signed velocity or replayed input from disconnected peer");
    std::cout << "resume_player=" << ticket.player << " original_car=" << car << " restored_signed_speed=" << speed << '\n';
}
