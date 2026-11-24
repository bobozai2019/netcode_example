#include "match.hpp"

#include <algorithm>
#include <cmath>

namespace yard {
namespace {
using namespace netcode;

bool finite(Reader& in, float& number) { return in.f32(number) && std::isfinite(number); }

void write_world(Writer& out, const CollisionWorld& world)
{
    out.u32(world.version);
    out.u8(static_cast<std::uint8_t>(world.obstacles.size()));
    for (const auto& o : world.obstacles) {
        out.u32(o.id); out.f32(o.x); out.f32(o.y); out.f32(o.half_width); out.f32(o.half_height);
    }
}

bool read_world(Reader& in, CollisionWorld& world)
{
    std::uint8_t count;
    if (!in.u32(world.version) || !world.version || !in.u8(count) || count > 16) return false;
    for (unsigned i = 0; i < count; ++i) {
        Obstacle o{};
        if (!in.u32(o.id) || !o.id || !finite(in, o.x) || !finite(in, o.y) || !finite(in, o.half_width) ||
            !finite(in, o.half_height) || o.half_width <= 0 || o.half_height <= 0) return false;
        world.obstacles.push_back(o);
    }
    return true;
}
}

void Match::record_world(Tick effective, CollisionWorld world)
{
    auto& slot = worlds_[effective];
    if (slot.version <= world.version) slot = std::move(world);
    while (worlds_.size() > 160) worlds_.erase(worlds_.begin());
}

const CollisionWorld& Match::world_at(Tick tick) const
{
    static const CollisionWorld empty;
    auto after = worlds_.upper_bound(tick);
    return after == worlds_.begin() ? empty : std::prev(after)->second;
}

void Match::remember_world(Tick effective)
{
    CollisionWorld world{++world_version_, blockers()};
    record_world(effective, world);
    auto packet = game_packet(GameMessage::CollisionWorld, room(), round());
    packet.u32(effective);
    write_world(packet, world);
    for (const auto& [id, member] : host_->members())
        if (member.peer && drivers_.at(id).prediction) link_->send(member.peer, Lane::Control, packet.bytes());
}

void Match::receive_world(Reader& in)
{
    Tick effective;
    CollisionWorld world;
    if (!in.u32(effective) || !effective || !read_world(in, world) || !in.done()) return;
    record_world(effective, std::move(world));
    if (prediction_.ready())
        prediction_.replay([this](Motion& m, Input i, Tick t) { predict_move(m, i, t); });
}

bool Match::prediction_request(const Event&, GameMessage type, Reader& in, Driver& driver)
{
    if (type != GameMessage::PredictionHello && type != GameMessage::InputHistory) return false;
    ObjectId id;
    Tick epoch;
    const auto* g = writers_.grant(driver.object);
    if (!in.u32(id) || id != driver.object || !in.u32(epoch) || epoch != (g ? g->epoch : 0) ||
        state_writer(id) != host_player) return true;
    if (type == GameMessage::PredictionHello) {
        if (in.done()) driver.prediction = true;
        return true;
    }
    std::uint8_t count;
    Tick first;
    if (!driver.prediction || !in.u32(first) || !first || !in.u8(count) || !count || count > 32 ||
        std::uint64_t(first) + count - 1 > std::uint64_t(driver.consumed) + prediction_.capacity) return true;
    std::vector<Input> inputs(count);
    for (auto& input : inputs)
        if (!finite(in, input.throttle) || std::abs(input.throttle) > 1.f ||
            !finite(in, input.steer) || std::abs(input.steer) > 1.f) return true;
    if (!in.done()) return true;
    for (std::size_t i = 0; i < inputs.size(); ++i) {
        const auto seq = first + static_cast<Tick>(i);
        if (seq > driver.consumed) driver.inputs.emplace(seq, inputs[i]);
    }
    return true;
}

void Match::send_history()
{
    const auto& history = prediction_.pending();
    if (history.empty()) return;
    const auto* g = writers_.grant(predicted_car_);
    auto out = game_packet(GameMessage::InputHistory, room(), round());
    out.u32(predicted_car_); out.u32(g ? g->epoch : 0); out.u32(history.front().sequence);
    const auto count = std::min<std::size_t>(32, history.size());
    out.u8(static_cast<std::uint8_t>(count));
    for (std::size_t i = 0; i < count; ++i) { out.f32(history[i].input.throttle); out.f32(history[i].input.steer); }
    link_->send(guest_->peer(), Lane::Game, out.bytes());
}

void Match::send_checkpoint(Peer peer, const Driver& driver)
{
    const auto* g = writers_.grant(driver.object);
    const auto& o = *object(driver.object);
    auto out = game_packet(GameMessage::Checkpoint, room(), round());
    out.u32(driver.object); out.u32(g ? g->epoch : 0); out.u32(tick_); out.u32(driver.consumed);
    out.u8(frozen_); out.f32(driver.speed);
    for (auto index : {0, 1, 2, 5}) out.f32(std::get<float>(o.values[index]));
    write_world(out, world_at(tick_));
    link_->send(peer, Lane::Game, out.bytes());
}

void Match::receive_checkpoint(Reader& in)
{
    ObjectId id; Tick epoch, tick, consumed;
    std::uint8_t frozen;
    Motion motion;
    CollisionWorld world;
    if (!in.u32(id) || !id || id != car() || state_writer(id) != host_player || !in.u32(epoch)) return;
    const auto* g = writers_.grant(id);
    if (epoch != (g ? g->epoch : 0) || !in.u32(tick) || !tick || !in.u32(consumed) ||
        !in.u8(frozen) || frozen > 1 || !finite(in, motion.speed) || std::abs(motion.speed) > 155.f) return;
    motion.car = *object(id);
    for (auto index : {0, 1, 2, 5}) {
        float value;
        if (!finite(in, value)) return;
        motion.car.values[index] = value;
    }
    motion.car.values[6] = std::abs(std::get<float>(motion.car.values[5]));
    if (!read_world(in, world) || !in.done()) return;
    if (frozen && !prediction_frozen_ && tick >= prediction_.checkpoint_tick()) prediction_.clear();
    record_world(tick, std::move(world));
    const bool first = !prediction_.ready();
    if (prediction_.reconcile(tick, consumed, motion, [this](Motion& m, Input i, Tick t) { predict_move(m, i, t); })) {
        predicted_car_ = id;
        prediction_frozen_ = frozen != 0;
        observe_time(tick);
        if (first) log("prediction_ready car=" + std::to_string(id) + " checkpoint=" + std::to_string(tick));
    }
}

void Match::observe_time(Tick tick)
{
    tick_ = std::max(tick_, tick);
    if (tick > clock_tick_) { clock_tick_ = tick; clock_time_ = frame_time_; }
}

void Match::observe(const Object& o)
{
    if (o.schema != Car) return;
    snapshots_[o.id].observe(o);
}

bool Match::buffered(ObjectId id) const
{
    auto it = snapshots_.find(id);
    return guest_ && !uses_local_state(id) && it != snapshots_.end() && it->second.ready();
}

Object Match::presentation(ObjectId id)
{
    const auto* canonical = object(id);
    if (!canonical) return {};
    auto view = writers_.presentation(*canonical);
    if (host_ || view.schema != Car) return view;
    if (predicts(id)) {
        for (const auto i : {0, 1, 2, 5, 6}) view.values[i] = prediction_.state().car.values[i];
    } else if (buffered(id)) {
        const auto window = snapshots_.at(id).at(render_tick_).value();
        for (const auto i : {0, 1, 2}) {
            const float a = std::get<float>(window.from.values[i]), b = std::get<float>(window.to.values[i]);
            view.values[i] = a + window.weight * (i == 2 ? std::remainder(b - a, 360.f) : b - a);
        }
    }
    auto& shown = displays_[id];
    const bool local = uses_local_state(id);
    if (shown.values != view.values || shown.local != local) {
        ++shown.revision; shown.values = view.values; shown.local = local;
    }
    view.revision = shown.revision;
    return view;
}
}
