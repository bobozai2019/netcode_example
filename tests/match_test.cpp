#include "match.hpp"
#include "transport/memory.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>

namespace {

using namespace netcode;
using namespace yard;
using namespace std::chrono_literals;

void check(bool ok, const char* message)
{
    if (ok) return;
    std::cerr << message << '\n';
    std::exit(1);
}

std::size_t count_log(const std::vector<std::string>& log, const std::string& text)
{
    return std::count_if(log.begin(), log.end(), [&](const auto& entry) {
        return entry.find(text) != std::string::npos;
    });
}

ObjectId find(const Match& match, SchemaId schema)
{
    for (const auto id : match.objects()) {
        if (match.object(id)->schema == schema) return id;
    }
    return 0;
}

float field(const Match& match, ObjectId object, std::size_t index)
{
    return std::get<float>(match.object(object)->values.at(index));
}

void motion_handoff(const Layout& layout, float speed, unsigned send_hz)
{
    auto host_transport = std::make_unique<MemoryTransport>();
    auto guest_transport = std::make_unique<MemoryTransport>();
    host_transport->link(*guest_transport);
    const auto send_period = std::chrono::nanoseconds(1s) / send_hz;
    Match host(layout, std::move(host_transport), true, 632, {}, {}, send_period);
    Match guest(layout, std::move(guest_transport), false, host.room(), {}, {}, send_period);
    TimePoint now{};
    auto advance = [&](int steps) {
        while (steps-- > 0) {
            now += 5ms;
            host.update(now);
            guest.update(now);
        }
    };
    advance(30);
    check(host.start() && host.set_client_authority(2, true), "motion room start");
    advance(160);
    const auto car = guest.car();
    check(guest.ready() && guest.uses_local_state(car) && host.state_writer(car) == 2, "motion grant not applied");
    const auto initial_x = field(host, car, 0);
    check(initial_x == 237.f, "motion drafts must start with identical positions");
    host.update(now);
    const auto before = host.acceptances();
    auto sample = game_packet(GameMessage::AuthorityState, host.room(), host.round());
    sample.u32(car);
    sample.u32(1);
    sample.u32(1000);
    sample.u32(host.tick() + 3);
    for (const auto slot : {0, 1, 2, 5, 6}) sample.f32(field(host, car, slot));
    sample.u16(4);
    sample.f32(speed);
    check(guest.transport().send(1, Lane::Game, sample.bytes()), "signed state send");
    host.update(now += 1ms);
    check(host.acceptances() == before + 1 && field(host, car, 0) == initial_x,
          "signed recovery at the same position was not accepted");
    check(host.set_client_authority(2, false), "signed recovery revoke");
    advance(8);
    check((field(host, car, 0) - initial_x) * speed > 0, "takeover advanced in the wrong direction");
    std::cout << "motion send_hz=" << send_hz << " position=" << initial_x << " speed=" << speed
              << " next_position=" << field(host, car, 0) << " physics=" << host.tick()
              << " sends=" << host.send_tick() << '\n';
}

std::pair<Tick, std::uint64_t> motion_rate(const Layout& layout, unsigned send_hz)
{
    auto host_transport = std::make_unique<MemoryTransport>();
    auto guest_transport = std::make_unique<MemoryTransport>();
    host_transport->link(*guest_transport);
    const auto period = std::chrono::nanoseconds(1s) / send_hz;
    Match host(layout, std::move(host_transport), true, 633, {}, {}, period);
    Match guest(layout, std::move(guest_transport), false, host.room(), {}, {}, period);
    TimePoint now{};
    auto advance = [&](int steps) {
        while (steps-- > 0) {
            now += 5ms;
            host.update(now);
            guest.update(now);
        }
    };
    advance(30);
    check(host.start() && host.set_client_authority(2, true), "rate room start");
    advance(160);
    const auto submissions = guest.submissions(), acceptances = host.acceptances();
    const auto sends = host.send_tick();
    const auto car = guest.car();
    guest.set_input({-0.5f, 0.f});
    advance(200);
    check(guest.submissions() - submissions == 30 && field(host, car, 0) < 200.f &&
          host.acceptances() > acceptances, "motion rate followed packet rate or state did not converge");
    std::cout << "rate send_hz=" << send_hz << " simulation=" << guest.submissions() - submissions
              << " sends=" << host.send_tick() - sends << " accepted=" << host.acceptances() - acceptances << '\n';
    return {host.send_tick() - sends, host.acceptances() - acceptances};
}

}

int main(int argc, char** argv)
{
    if (argc != 2) return 2;
    const Layout layout(argv[1]);
    motion_handoff(layout, 60.f, 20);
    motion_handoff(layout, -60.f, 20);
    const auto slow = motion_rate(layout, 10), fast = motion_rate(layout, 40);
    check(slow.first < fast.first && slow.second < fast.second, "packet rate did not affect coalescing");
    std::vector<std::string> host_log, b_log, c_log;
    auto trace = [](auto& lines) {
        return [&lines](const std::string& text) { lines.push_back(text); };
    };
    auto transport = std::make_unique<MemoryTransport>();
    auto& hub = *transport;
    Match a(layout, std::move(transport), true, 631, {}, trace(host_log));

    auto join = [&](auto& log, std::optional<ResumeTicket> ticket = {}) {
        auto link = std::make_unique<MemoryTransport>();
        hub.link(*link);
        return std::make_unique<Match>(layout, std::move(link), false, a.room(), ticket, trace(log));
    };
    auto b = join(b_log);
    auto c = join(c_log);
    std::unique_ptr<Match> extra;
    TimePoint now{};
    auto advance = [&](int steps) {
        for (int i = 0; i < steps; ++i) {
            now += 10ms;
            a.update(now);
            b->update(now);
            c->update(now);
            if (extra) extra->update(now);
        }
    };
    advance(30);
    check(a.seats() == 3 && a.start(), "Three members must join before first round");
    advance(30);
    check(b->ready() && c->ready() && a.ready_guests() == 2, "Baseline did not cross ready fence");
    const auto player = b->player();
    const auto car = b->car();
    const auto round = a.round();
    const auto gate = find(a, Gate);
    check(car && b->objects() == a.objects(), "Baseline IDs differ");
    b->set_input({0.75f, 0.f});
    advance(20);
    check(field(a, car, 5) == 0.75f && field(*b, car, 5) == 0.75f &&
          count_log(host_log, "input player=2") && count_log(host_log, "authority_write") &&
          count_log(b_log, "net_input_x=0.750000"), "Input-authority-capture-send-apply chain failed");
    std::cout << "input player=" << player << " object=" << car
              << " host=0.75 guest=0.75 sample=" << b->object(car)->sample_tick << '\n';

    check(!b->open_gate(true), "Guest API sent Server RPC on public gate");
    auto malformed = game_packet(GameMessage::Rpc, a.room(), round);
    malformed.u32(gate);
    malformed.u16(TryOpen);
    malformed.u32(1);
    malformed.u32(gate);
    check(b->transport().send(1, Lane::Game, malformed.bytes()), "Failed to inject wrong-owner call");
    advance(10);
    check(!std::get<bool>(a.object(gate)->values[5]), "Public gate accepted wrong-owner receive");
    check(b->open_gate(), "Owned call not queued");
    advance(20);
    check(std::get<bool>(b->object(gate)->values[5]) && std::get<bool>(c->object(gate)->values[5]),
          "Gate approval did not replicate");
    check(b->open_gate(), "Second owned call not queued");
    advance(20);
    check(b->notice() == "The gate is already open" && c->notice() == "The yard gate is open",
          "Business denial not directed to the caller");
    check(c->horn() && c->notice().find("Horn") == 0 && b->notice().find("Horn") == std::string::npos,
          "Guest multicast left its originating client");

    auto& b_link = static_cast<MemoryTransport&>(b->transport());
    b_link.next_game(Delivery::Drop);
    check(b->barrier(true), "Reliable spawn not queued");
    b_link.next_game(Delivery::Duplicate);
    check(b->barrier(false), "Reliable delete not queued");
    advance(30);
    check(count_log(host_log, "barrier_spawn") == 1 && count_log(host_log, "barrier_removed") == 1 &&
          !find(a, Barrier) && !b->rpc_pending(), "Reliable order, retry or deduplication failed");
    std::cout << "door approval + directed denial + wrong-owner rejection + reliable barrier order\n";

    b->set_input({-0.5f, 0.f});
    check(a.barrier(true), "Host barrier not created");
    advance(25);
    const auto old_barrier = find(a, Barrier);
    const auto before = field(a, car, 0);
    const auto preserved = b->ticket();
    b->disconnect();
    advance(10);
    check(a.seats() == 3 && a.ready_guests() == 1 && a.object(car) &&
          field(a, car, 5) == 0.f && std::abs(field(a, car, 0) - before) > 0.01f,
          "Disconnect did not retain and continue simulating the original car");
    check(a.barrier(false) && a.barrier(true), "Host could not modify world during disconnect");
    advance(20);
    std::vector<std::string> extra_log;
    extra = join(extra_log);
    advance(15);
    check(extra->rejected() == Reject::Locked, "New player joined a locked round");
    auto wrong = preserved;
    wrong.key[0] ^= 1;
    extra = join(extra_log, wrong);
    advance(15);
    check(extra->rejected() == Reject::BadResume, "Wrong ticket took over a seat");
    b = join(b_log, preserved);
    advance(30);
    check(b->ready() && b->player() == player && b->car() == car && !b->object(old_barrier) &&
          b->object(find(a, Barrier)) && b->objects() == a.objects(), "Reconnect world or identity is stale");
    extra = join(extra_log, preserved);
    advance(15);
    check(extra->rejected() == Reject::BadResume, "Simultaneous resume replaced current peer");
    b->set_input({-0.5f, 0.15f});
    advance(30);
    check(field(a, car, 5) == -0.5f && field(*b, car, 5) == -0.5f,
          "Resumed player cannot control original car");
    std::cout << "resume player=" << player << " car=" << car << " replaced stale barrier=" << old_barrier << '\n';

    const auto borrowed = a.car();
    const auto original_x = field(a, borrowed, 0);
    check(a.cycle_driver(), "host could not lend its car");
    advance(20);
    check(b->controlled_car() == borrowed && b->state_writer(borrowed) == player &&
          c->controlled_car() == c->car(), "lending changed the wrong driver's input target");
    b->set_input({1.f, 0.f});
    advance(30);
    check(field(a, borrowed, 0) > original_x && a.object(borrowed)->owner == host_player, "borrower did not drive the host car");
    check(a.cycle_driver(), "second driver could not take the car");
    advance(20);
    check(c->controlled_car() == borrowed && b->controlled_car() == car, "driver handoff failed");
    c->set_input({-.8f, 0.f});
    advance(25);
    check(field(a, borrowed, 5) == -.8f && a.object(borrowed)->owner == host_player, "second driver lost state or ownership");
    check(a.cycle_driver(), "host could not take its car back");
    advance(18);
    check(a.state_writer(borrowed) == host_player && c->controlled_car() == c->car(), "failed to return borrowed car");
    std::cout << "borrowed car=" << borrowed << " writers=1,2,3,1 owner=1\n";
    a.end_round();
    advance(10);
    check(a.start() && a.round() != round, "Did not start second round in same room");
    advance(30);
    auto stale = game_packet(GameMessage::Input, a.room(), round);
    stale.u32(40000);
    stale.f32(0.9f);
    stale.f32(0.f);
    check(b->transport().send(1, Lane::Game, stale.bytes()), "Failed to inject previous-round input");
    extra = join(extra_log, preserved);
    advance(20);
    check(extra->rejected() == Reject::BadResume && field(a, b->car(), 5) == 0.f,
          "Previous-round ticket or input was accepted");
    std::cout << "new round discards stale input and resume ticket\n";
}
