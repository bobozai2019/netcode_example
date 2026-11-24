#include "match.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace yard {
namespace {

using namespace netcode;
using namespace std::chrono_literals;
constexpr auto simulation_period = 33333333ns;
constexpr float dt = 1.0f / 30.0f;
constexpr float rad = 0.01745329252f;

float number(const Object& object, std::size_t index) { return std::get<float>(object.values.at(index)); }

bool valid_input(float value) { return std::isfinite(value) && value >= -1.f && value <= 1.f; }

Bytes pack_speed(float speed)
{
    Writer out;
    out.f32(speed);
    return out.bytes();
}

bool read_speed(const Bytes& bytes, float& speed)
{
    Reader in(bytes);
    return in.f32(speed) && in.done() && std::isfinite(speed) && std::abs(speed) <= 155.f;
}

Values drive(const Object& car, float& speed, Input input, const std::vector<Obstacle>& blockers)
{
    speed += (input.throttle * 155.f - speed) * 0.09f;
    if (std::abs(speed) < 0.015f) speed = 0;
    const auto angle = std::remainder(number(car, 2) + input.steer * 125.f * dt, 360.f);
    auto x = std::clamp(number(car, 0) + std::cos(angle * rad) * speed * dt, 38.f, 922.f);
    auto y = std::clamp(number(car, 1) - std::sin(angle * rad) * speed * dt, 40.f, 550.f);
    for (const auto& obstacle : blockers) {
        if (std::abs(x - obstacle.x) < obstacle.half_width && std::abs(y - obstacle.y) < obstacle.half_height) {
            x = number(car, 0);
            y = number(car, 1);
            speed = 0;
            break;
        }
    }
    return {x, y, angle, input.throttle, std::abs(input.throttle)};
}

bool plausible_motion(const Object& car, const AuthoritySample& before, const AuthoritySample& next, Tick now)
{
    if (next.source_step <= before.source_step || std::uint64_t(next.source_step) > std::uint64_t(now) + 8)
        return false;
    const auto x = std::get<float>(next.values[0]), y = std::get<float>(next.values[1]);
    const auto angle = std::get<float>(next.values[2]), throttle = std::get<float>(next.values[3]);
    const float elapsed = dt * float(next.source_step - before.source_step);
    float speed;
    return read_speed(next.recovery, speed) && valid_input(throttle) &&
           std::get<float>(next.values[4]) == std::abs(throttle) &&
           x >= 38.f && x <= 922.f && y >= 40.f && y <= 550.f && std::abs(angle) <= 180.f &&
           std::hypot(x - number(car, 0), y - number(car, 1)) <= 155.f * elapsed + 0.15f &&
           std::abs(std::remainder(angle - number(car, 2), 360.f)) <= 125.f * elapsed + 0.15f;
}

}

Match::Match(const Layout& layout, std::unique_ptr<Transport> transport, bool host,
             RoomId room, std::optional<ResumeTicket> ticket, Log trace, std::chrono::nanoseconds network_period)
    : link_(std::move(transport)), authority_(layout.schemas()), replica_(layout.schemas()),
      rpc_(*link_, host, [this](ObjectId id) -> std::optional<PlayerId> {
          if (const auto* found = object(id)) return found->owner;
          return std::nullopt;
      }, [this](const RpcCall& call) { receive_rpc(call); }, [this](Peer peer, ObjectId id) { return authority_.known(peer,id); }),
      writers_(*link_, layout.schemas(), [this](ObjectId id) { return object(id); },
          [this](ObjectId id, const Values& values, Tick now) {
              const auto& g = *writers_.grant(id);
              const bool report = !g.confirmed || object(id)->values[5] != values[5];
              if (!authority_.capture(id, values, now)) return false;
              if (report) log("authority_accept object=" + std::to_string(id) +
                  " writer=" + std::to_string(g.writer) + " tick=" + std::to_string(now) +
                  " net_input_x=" + std::to_string(std::get<float>(values[5])));
              return true;
          }, [this](const ObjectGrant& g) { authority_changed(g); },
          [this](Peer peer, ObjectId id) { return authority_.known(peer, id); }),
      trace_(std::move(trace)), network_period_(network_period)
{
    layout.validate_yard();
    if (host) host_.emplace(*link_, room);
    else guest_.emplace(*link_, room, ticket);
    if (!writers_.register_model(Car, 1, {10, 11, 12, 20, 30}, 4,
            [this](const Object& car, const AuthoritySample& before, const AuthoritySample& next, Tick now) {
                if (plausible_motion(car, before, next, now)) return true;
                drivers_.at(car.owner).delegate = false;
                log("authority_motion_rejected object=" + std::to_string(car.id));
                return false;
            })) throw std::invalid_argument("Incompatible car authority model");
    rpc_.register_method({TryOpen, false, Direction::Server, Reliability::Reliable, 4});
    rpc_.register_method({OpenDenied, false, Direction::Client, Reliability::Reliable, 1});
    rpc_.register_method({PlaceBarrier, false, Direction::Server, Reliability::Reliable, 0});
    rpc_.register_method({RemoveBarrier, false, Direction::Server, Reliability::Reliable, 0});
    rpc_.register_method({RoomNotice, true, Direction::NetMulticast, Reliability::Reliable, 1});
    rpc_.register_method({Horn, false, Direction::NetMulticast, Reliability::BestEffort, 0});
}

RoomPhase Match::phase() const { return host_ ? host_->phase() : guest_->phase(); }
RoomId Match::room() const { return host_ ? host_->id() : guest_->ticket().room; }
RoundId Match::round() const
{
    if (phase() != RoomPhase::Playing) return 0;
    return host_ ? host_->round() : guest_->ticket().round;
}
PlayerId Match::player() const { return host_ ? host_player : guest_->ticket().player; }
ResumeTicket Match::ticket() const { return guest_ ? guest_->ticket() : ResumeTicket{}; }
Reject Match::rejected() const { return guest_ ? guest_->rejected() : Reject::None; }
Disconnect Match::loss() const { return guest_ ? guest_->disconnected() : Disconnect::None; }
std::size_t Match::seats() const { return host_ ? host_->members().size() : guest_->seats(); }
bool Match::ready() const { return host_ ? phase() == RoomPhase::Playing : guest_->ready(); }
ObjectId Match::car() const { return find(Car, player()); }
std::size_t Match::ready_guests() const
{
    if (!host_) return 0;
    return std::count_if(host_->members().begin(), host_->members().end(), [](const auto& member) {
        return member.second.peer && member.second.ready;
    });
}

std::vector<ObjectId> Match::objects() const
{
    if (host_) return authority_.active();
    std::vector<ObjectId> result;
    for (const auto& [id, obj] : replica_.objects()) result.push_back(id);
    return result;
}

const Object* Match::object(ObjectId id) const
{
    if (host_) return authority_.get(id);
    const auto found = replica_.objects().find(id);
    return found == replica_.objects().end() ? nullptr : &found->second;
}

std::uint64_t Match::digest() const
{
    std::uint64_t hash = 14695981039346656037ull;
    for (const auto id : objects()) {
        const auto& obj = *object(id);
        Writer w;
        w.u32(id);
        w.u16(obj.schema);
        w.u32(obj.owner);
        for (const auto& value : obj.values) write_value(w, value);
        for (const auto byte : w.bytes()) {
            hash ^= byte;
            hash *= 1099511628211ull;
        }
    }
    return hash;
}

void Match::log(const std::string& message) const { if (trace_) trace_(message); }

ObjectId Match::find(SchemaId schema, PlayerId owner) const
{
    for (const auto id : objects()) {
        const auto* obj = object(id);
        if (obj->schema == schema && (!owner || obj->owner == owner)) return id;
    }
    return 0;
}

ObjectId Match::spawn(SchemaId schema, PlayerId owner, const Values& values)
{
    const auto id = next_object_++;
    if (!authority_.create(id, schema, owner, values, tick_)) {
        throw std::runtime_error("Invalid template spawn for schema " + std::to_string(schema));
    }
    return id;
}

void Match::clear_world()
{
    authority_.clear();
    replica_.clear();
    drivers_.clear();
    attached_.clear();
    rpc_.reset(room(), round(), player());
    prediction_.clear();
    prediction_frozen_ = false;
    predicted_car_ = world_version_ = clock_tick_ = 0;
    render_tick_ = 0;
    worlds_.clear();
    snapshots_.clear();
    displays_.clear();
    writers_.reset(room(), round(), player(), guest_ ? guest_->peer() : 0);
    next_object_ = 1;
    gate_ = beacon_ = input_sequence_ = tick_ = send_tick_ = 0;
    sample_count_ = 0;
    local_ = {};
    notice_.clear();
    frozen_ = false;
}

void Match::begin(std::size_t count)
{
    clear_world();
    tick_ = 1;
    std::size_t slot = 0;
    for (const auto& [id, member] : host_->members()) {
        const auto car_id = spawn(Car, id, {205.f + 32.f * float(slot), 210.f + 53.f * float(slot),
                                           0.f, 1.f, 1.f, 0.f, 0.f});
        drivers_.emplace(id, Driver{car_id});
        ++slot;
    }
    gate_ = spawn(Gate, host_player, {345.f, 290.f, 0.f, 1.f, 1.f, false});
    beacon_ = spawn(Beacon, 0, {690.f, 420.f, 0.f, 22.f, 20.f, 0.f, 1.f, 1.f, 1.f, 0.f});
    if (profile_enabled_) spawn(Profile, host_player, {std::int32_t(16777217), Vector2{2,-3}, Vector3{4,5,-6},
        Rotation{0,0,1,0}, std::string(u8"\u73a9\u5bb6\U0001f680"), IntArray{7,-2,16777219}, FloatArray{.25f,-.5f}});
    for (std::size_t i = objects().size(); i < count; ++i) {
        spawn(Load, 0, {80.f + float(i % 16) * 49.f, 76.f + float(i / 16) * 72.f,
                        0.f, 1.f, 1.f, float(i)});
    }
    remember_world(tick_);
    log("round_started round=" + std::to_string(round()) + " objects=" + std::to_string(objects().size()));
}

bool Match::start(std::size_t count)
{
    if (!host_ || count > 100 || !host_->start()) return false;
    begin(count);
    return true;
}

void Match::end_round()
{
    if (host_ && host_->end_round()) clear_world();
}

void Match::end_room()
{
    if (host_) {
        host_->end_room();
        clear_world();
    }
}

void Match::disconnect()
{
    if (guest_ && guest_->peer()) link_->close(guest_->peer());
}

void Match::set_input(Input input)
{
    if (valid_input(input.throttle) && valid_input(input.steer)) local_ = input;
}

bool Match::set_client_authority(PlayerId player, bool enabled)
{
    auto driver = drivers_.find(player);
    if (!host_ || phase() != RoomPhase::Playing || player == host_player || driver == drivers_.end())
        return false;
    driver->second.delegate = enabled;
    if (!enabled) return writers_.assign(driver->second.object, host_player, tick_);
    return true;
}

bool Match::toggle_guest_authority(unsigned seat)
{
    if (!host_ || !seat) return false;
    for (const auto& [id, driver] : drivers_) {
        if (id != host_player && --seat == 0) return set_client_authority(id, !driver.delegate);
    }
    return false;
}

void Match::authority_changed(const ObjectGrant& g)
{
    float speed = 0.f;
    read_speed(g.sample.recovery, speed);
    if (host_) {
        auto& driver = drivers_.at(object(g.object)->owner);
        driver.input = {};
        driver.last_input = driver.sequence = 0;
        driver.prediction = false;
        driver.consumed = 0;
        driver.inputs.clear();
        if (g.writer == host_player) driver.speed = speed;
    }
    if (g.object == predicted_car_) { prediction_.clear(); predicted_car_ = 0; }
    notice_ = "Object " + std::to_string(g.object) + " controlled by player " + std::to_string(g.writer);
    log("authority_grant object=" + std::to_string(g.object) + " writer=" + std::to_string(g.writer) +
        " epoch=" + std::to_string(g.epoch) + " step=" + std::to_string(g.sample.source_step) +
        " speed=" + std::to_string(speed));
}

void Match::freeze(bool frozen)
{
    frozen_ = frozen;
    if (!frozen || !host_) return;
    for (const auto& [id, driver] : drivers_)
        if (state_writer(driver.object) != host_player) writers_.assign(driver.object, host_player, tick_);
}

bool Match::open_gate(bool public_object)
{
    const auto door = host_ ? gate_ : find(Gate);
    if (!ready() || !door) return false;
    Writer arg;
    arg.u32(door);
    return rpc_.invoke(public_object ? door : car(), TryOpen, arg.bytes());
}

bool Match::barrier(bool create)
{
    return ready() && rpc_.invoke(car(), create ? PlaceBarrier : RemoveBarrier);
}

bool Match::horn() { return ready() && rpc_.invoke(car(), Horn); }

bool Match::kick(PlayerId player) { return host_ && host_->kick(player); }
bool Match::chat(std::string_view text) { return host_ ? host_->chat(text) : guest_->chat(text); }

std::vector<PlayerId> Match::players() const
{
    if (guest_) return guest_->players();
    std::vector<PlayerId> players;
    for (const auto& [id, member] : host_->members()) players.push_back(id);
    return players;
}

const std::deque<RoomMessage>& Match::messages() const
{
    return host_ ? host_->messages() : guest_->messages();
}

void Match::receive(const Event& event)
{
    if (event.type == EventType::Closed && host_) {
        writers_.detach(event.peer, tick_);
        if (const auto* member = host_->member(event.peer)) {
            const auto driver = drivers_.find(member->id);
            if (driver != drivers_.end()) {
                driver->second.input = {};
                driver->second.sequence = 0;
                driver->second.last_input = 0;
                driver->second.prediction = false;
                driver->second.consumed = 0;
                driver->second.inputs.clear();
            }
            log("peer_lost player=" + std::to_string(member->id));
        }
        authority_.detach(event.peer);
        rpc_.detach(event.peer);
        attached_.erase(event.peer);
    }
    if (writers_.receive(event, tick_)) return;
    if (guest_ && event.type == EventType::Message && event.lane == Lane::Control &&
        event.peer == guest_->peer() && !event.payload.empty() &&
        event.payload.front() == static_cast<std::uint8_t>(GameMessage::CollisionWorld)) {
        Reader env(event.payload);
        GameMessage type;
        if (read_game_header(env, type, room(), round())) receive_world(env);
        return;
    }
    const auto previous_round = round();
    if (host_) host_->receive(event);
    else guest_->receive(event);
    if (guest_ && round() != previous_round) clear_world();
    if (phase() != RoomPhase::Playing || event.type != EventType::Message || event.lane != Lane::Game) return;
    Reader reader(event.payload);
    GameMessage type;
    if (!read_game_header(reader, type, room(), round())) return;
    if (host_) host_message(event, type, reader);
    else if (event.peer == guest_->peer()) guest_message(event, type, reader);
}

void Match::host_message(const Event& event, GameMessage type, Reader& reader)
{
    const auto* member = host_->member(event.peer);
    if (!member || !attached_.count(event.peer)) return;
    if (type == GameMessage::StateAck) {
        if (!authority_.acknowledge(event.peer, reader)) return;
        if (!member->ready && authority_.baseline_complete(event.peer)) {
            host_->ready(event.peer);
            writers_.attach(event.peer, member->id);
            rpc_.attach(event.peer, member->id);
            log("baseline_ack player=" + std::to_string(member->id));
        }
        return;
    }
    if (!member->ready) return;
    if (prediction_request(event, type, reader, drivers_.at(member->id))) return;
    if (type == GameMessage::Input || type == GameMessage::AuthorityInput) {
        std::uint32_t sequence;
        Input input;
        auto& driver = drivers_.at(member->id);
        if (driver.prediction) return;
        const auto* grant = writers_.grant(driver.object);
        if (grant && grant->writer != host_player) return;
        if (type == GameMessage::AuthorityInput) {
            std::uint32_t epoch;
            if (!grant || !reader.u32(epoch) || epoch != grant->epoch) return;
        } else if (grant && writers_.supports(member->id, Car)) return;
        if (!reader.u32(sequence) || !reader.f32(input.throttle) || !reader.f32(input.steer) ||
            !reader.done() || sequence <= driver.sequence ||
            !valid_input(input.throttle) || !valid_input(input.steer)) return;
        if (input.throttle != driver.input.throttle || input.steer != driver.input.steer) {
            log("input player=" + std::to_string(member->id) + " seq=" + std::to_string(sequence) +
                " throttle=" + std::to_string(input.throttle));
        }
        driver.sequence = sequence;
        driver.input = input;
        driver.last_input = tick_;
    } else {
        rpc_.receive(event.peer, type, reader);
    }
}

void Match::guest_message(const Event& event, GameMessage type, Reader& reader)
{
    if (type == GameMessage::Checkpoint) {
        if (guest_->ready()) receive_checkpoint(reader);
    } else if (type == GameMessage::Snapshot) {
        AppliedSnapshot applied;
        if (replica_.apply(reader, room(), round(), applied)) {
            link_->send(event.peer, Lane::Game, applied.ack);
            for (const auto id : applied.hidden) writers_.unobserve(id);
            for (const auto id : applied.destroyed) writers_.forget(id);
            for (const auto id : applied.changed) {
                if (const auto* obj = object(id)) { observe_time(obj->sample_tick); observe(*obj); }
                else {
                    snapshots_.erase(id);
                    displays_.erase(id);
                    log("replica_removed object=" + std::to_string(id));
                }
            }
            const auto own_car = car();
            if (own_car && std::find(applied.changed.begin(), applied.changed.end(), own_car) !=
                applied.changed.end()) {
                const auto& obj = *object(own_car);
                log("applied object=" + std::to_string(own_car) + " sample=" +
                    std::to_string(obj.sample_tick) + " send=" + std::to_string(applied.send_tick) +
                    " net_input_x=" + std::to_string(number(obj, 5)));
            }
        }
    } else if (type == GameMessage::Ready && reader.done() && !guest_->ready() && car()) {
        guest_->mark_ready();
        rpc_.attach(event.peer, host_player);
        log("ready player=" + std::to_string(player()) + " car=" + std::to_string(car()) +
            " resumed=" + std::to_string(guest_->resumed()));
    } else if (guest_->ready()) {
        rpc_.receive(event.peer, type, reader);
    }
}

void Match::network_step()
{
    ++send_tick_;
    if (host_) {
        for (const auto& [id, member] : host_->members()) {
            if (!member.peer) continue;
            auto& driver = drivers_.at(id);
            if (!frozen_ && member.ready && driver.delegate && state_writer(driver.object) == host_player &&
                writers_.supports(id, Car)) writers_.assign(driver.object, id, tick_, pack_speed(driver.speed), tick_);
            if (attached_.insert(member.peer).second) authority_.attach(member.peer);
            for (const auto& bytes : authority_.packets(member.peer, room(), round(), send_tick_)) {
                link_->send(member.peer, Lane::Game, bytes);
            }
            const auto* grant = writers_.grant(driver.object);
            if (member.ready && driver.prediction && state_writer(driver.object) == host_player)
                send_checkpoint(member.peer, driver);
            if (member.ready && !driver.sequence && !driver.consumed && !(grant && grant->writer == id && grant->confirmed)) {
                link_->send(member.peer, Lane::Game, game_packet(GameMessage::Ready, room(), round()).bytes());
            }
        }
    } else if (guest_->ready() && state_writer(car()) == host_player) {
        const auto* grant = writers_.grant(car());
        if (prediction_.ready()) { send_history(); writers_.flush(tick_); return; }
        auto hello = game_packet(GameMessage::PredictionHello, room(), round());
        hello.u32(car());
        hello.u32(grant ? grant->epoch : 0);
        link_->send(guest_->peer(), Lane::Game, hello.bytes());
        auto input = game_packet(grant ? GameMessage::AuthorityInput : GameMessage::Input, room(), round());
        if (grant) input.u32(grant->epoch);
        input.u32(++input_sequence_);
        input.f32(local_.throttle);
        input.f32(local_.steer);
        link_->send(guest_->peer(), Lane::Game, input.bytes());
    }
    writers_.flush(tick_);
}

std::vector<Obstacle> Match::blockers() const
{
    std::vector<Obstacle> result;
    const auto active = objects();
    for (const auto id : active) {
        const auto* obj = object(id);
        if (obj->schema == Barrier || (obj->schema == Gate && !std::get<bool>(obj->values[5])))
            result.push_back({id, number(*obj, 0), number(*obj, 1), obj->schema == Gate ? 18.f : 22.f,
                              obj->schema == Gate ? 75.f : 20.f});
    }
    return result;
}

void Match::simulate_local_car(ObjectId id, Input input)
{
    const auto* g = writers_.grant(id);
    if (!g || g->writer != player()) return;
    auto view = *object(id);
    writers_.overlay(view);
    float speed;
    if (!read_speed(g->sample.recovery, speed)) return;
    auto fields = drive(view, speed, input, blockers());
    const bool report = !g->sample.sequence || fields[3] != g->sample.values[3];
    if (writers_.submit(id, g->epoch, g->sample.source_step + 1, std::move(fields), pack_speed(speed)) && report)
        log("authority_submit object=" + std::to_string(id) + " writer=" + std::to_string(player()) +
            " net_input_x=" + std::to_string(input.throttle));
}

void Match::predict_move(Motion& state, Input input, Tick tick) const
{
    const auto values = drive(state.car, state.speed, input, world_at(tick).obstacles);
    auto& car = state.car.values;
    car[0] = values[0]; car[1] = values[1]; car[2] = values[2];
    car[5] = values[3]; car[6] = values[4];
}

ObjectId Match::controlled_car() const
{
    const auto own = car();
    for (const auto id : objects())
        if (id != own && object(id)->schema == Car && state_writer(id) == player() && guest_) return id;
    return own;
}

bool Match::grant_car(ObjectId id, PlayerId writer)
{
    const auto* obj = object(id);
    if (!host_ || !obj || obj->schema != Car || !writer) return false;
    auto& driver = drivers_.at(obj->owner);
    const bool accepted = writers_.assign(id, writer, tick_, pack_speed(driver.speed), tick_);
    if (accepted) driver.delegate = writer == obj->owner && writer != host_player;
    return accepted;
}

bool Match::cycle_driver()
{
    if (!host_ || !car()) return false;
    std::vector<PlayerId> candidates{host_player};
    for (const auto& [id, member] : host_->members())
        if (member.ready && writers_.supports(id, Car)) candidates.push_back(id);
    const auto it = std::upper_bound(candidates.begin(), candidates.end(), state_writer(car()));
    return grant_car(car(), it == candidates.end() ? host_player : *it);
}

void Match::simulate()
{
    if (frozen_) return;
    ++tick_;
    const auto active = objects();
    sample_count_ += active.size();
    const auto obstacles = blockers();
    for (auto& [id, driver] : drivers_) {
        if (state_writer(driver.object) != host_player) {
            const auto* grant = writers_.grant(driver.object);
            if (tick_ - grant->committed_at <= 90) continue;
            driver.delegate = false;
            writers_.assign(driver.object, host_player, tick_);
        }
        const auto& car = *object(driver.object);
        Input input = id == host_player ? local_ :
            (tick_ - driver.last_input <= 8 ? driver.input : Input{});
        if (driver.prediction) {
            const auto next = driver.inputs.find(driver.consumed + 1);
            if (next != driver.inputs.end()) {
                input = next->second;
                if (input.throttle != driver.input.throttle || input.steer != driver.input.steer)
                    log("input player=" + std::to_string(id) + " seq=" + std::to_string(next->first) +
                        " throttle=" + std::to_string(input.throttle));
                driver.consumed = next->first;
                driver.last_input = tick_;
                driver.input = input;
                driver.inputs.erase(next);
            }
        }
        const auto fields = drive(car, driver.speed, input, obstacles);
        if (input.throttle != number(car, 5)) {
            log("authority_write object=" + std::to_string(car.id) + " tick=" + std::to_string(tick_) +
                " net_input_x=" + std::to_string(input.throttle));
        }
        authority_.capture(car.id, {fields[0], fields[1], fields[2], car.values[3], car.values[4],
                                    fields[3], fields[4]}, tick_);
    }
    if (tick_ % 3 == 0) {
        const float t = float(tick_) * dt;
        const float scale = 1.f + 0.15f * std::sin(t);
        authority_.capture(beacon_, {690.f + 25.f * std::sin(t), 420.f + 10.f * std::cos(t),
                                      6.f * std::sin(t), 22.f, std::remainder(t * 75.f, 360.f),
                                      12.f * std::sin(t), scale, scale, scale, t}, tick_);
        for (const auto id : active) {
            const auto* obj = object(id);
            if (obj->schema != Load || id % 4 != (tick_ / 3) % 4) continue;
            auto values = obj->values;
            values.back() = float(tick_) + float(id);
            values[2] = std::remainder(t * 30.f, 360.f);
            values[3] = 1.f + 0.15f * std::sin(t + float(id));
            values[4] = 1.f + 0.15f * std::cos(t + float(id));
            authority_.capture(id, values, tick_);
        }
    }
}

void Match::update(TimePoint now)
{
    frame_time_ = now;
    for (const auto& event : link_->poll(now)) receive(event);
    if (guest_ && clock_tick_) {
        const auto elapsed = std::chrono::duration<double>(now - clock_time_).count();
        render_tick_ = std::max(render_tick_, double(clock_tick_) + std::clamp(elapsed * 30.0, 0.0, 6.0) - 3.0);
    }
    if (phase() != RoomPhase::Playing) {
        next_simulate_ = next_network_ = now;
        return;
    }
    if (host_ || (guest_->ready() && car())) {
        for (int catch_up = 0; now >= next_simulate_ && catch_up < 5; ++catch_up) {
            if (host_) simulate();
            else {
                const auto controlled = controlled_car();
                if (prediction_.ready() && !prediction_frozen_)
                    prediction_.advance(controlled == predicted_car_ ? local_ : Input{},
                        [this](Motion& m, Input i, Tick t) { predict_move(m, i, t); });
                for (const auto id : objects())
                    if (object(id)->schema == Car && state_writer(id) == player())
                        simulate_local_car(id, id == controlled ? local_ : Input{});
            }
            next_simulate_ += simulation_period;
        }
        if (next_simulate_ < now) next_simulate_ = now + simulation_period;
    } else next_simulate_ = now;
    if (now >= next_network_) {
        network_step();
        next_network_ += network_period_;
        if (now >= next_network_) next_network_ = now + network_period_;
    }
    rpc_.update(now);
}

void Match::receive_rpc(const RpcCall& call)
{
    const auto id = call.method;
    if (id == Horn || id == RoomNotice || id == OpenDenied) {
        if (id == Horn) notice_ = "Horn from player " + std::to_string(call.sender);
        else if (id == RoomNotice) notice_ = "The yard gate is open";
        else notice_ = call.arguments.front() == 1 ? "Drive closer to the gate" : "The gate is already open";
        log("rpc method=" + std::to_string(id) + " sender=" + std::to_string(call.sender) + " " + notice_);
        return;
    }
    if (!host_) return;
    const auto* car = object(call.object);
    if (!car || car->schema != Car || car->owner != call.sender) return;
    if (id == TryOpen) {
        Reader r(call.arguments);
        ObjectId door;
        if (!r.u32(door) || door != gate_) return;
        const auto& gate = *object(gate_);
        if (std::get<bool>(gate.values[5])) {
            rpc_.invoke(car->id, OpenDenied, {2});
        } else if (std::hypot(number(gate, 0) - number(*car, 0), number(gate, 1) - number(*car, 1)) > 155.f) {
            rpc_.invoke(car->id, OpenDenied, {1});
        } else {
            auto values = gate.values;
            values[2] = 72.f;
            values[5] = true;
            authority_.capture(gate_, values, tick_);
            if (const auto profile = profile_enabled_ ? find(Profile) : 0) {
                auto reward = object(profile)->values;
                reward[0] = std::get<std::int32_t>(reward[0]) + 2;
                reward[4] = std::string(u8"\u901a\u5173");
                reward[5] = IntArray{7};
                reward[6] = FloatArray{};
                authority_.capture(profile, reward, tick_);
            }
            remember_world(tick_ + 1);
            rpc_.invoke(0, RoomNotice, {1});
            log("door_open player=" + std::to_string(call.sender));
        }
    } else if (id == PlaceBarrier) {
        if (find(Barrier, call.sender)) return;
        const float x = std::clamp(number(*car, 0) + std::cos(number(*car, 2) * rad) * 55.f, 54.f, 906.f);
        const float y = std::clamp(number(*car, 1) - std::sin(number(*car, 2) * rad) * 55.f, 54.f, 530.f);
        const auto barrier = spawn(Barrier, call.sender, {x, y, 0.f, 1.f, 1.f, float(call.sender)});
        remember_world(tick_ + 1);
        log("barrier_spawn object=" + std::to_string(barrier));
    } else if (id == RemoveBarrier) {
        const auto id = find(Barrier, call.sender);
        if (id && authority_.destroy(id, tick_)) {
            writers_.forget(id);
            remember_world(tick_ + 1);
            log("barrier_removed object=" + std::to_string(id));
        }
    }
}

}
