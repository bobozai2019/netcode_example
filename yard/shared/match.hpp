#pragma once

#include "layout.hpp"
#include "session/rpc.hpp"
#include "session/object_authority.hpp"
#include "state/prediction.hpp"
#include "state/snapshot_buffer.hpp"

#include <functional>
#include <memory>
#include <set>

namespace yard {

struct Input { float throttle = 0, steer = 0; };
struct Obstacle { netcode::ObjectId id; float x, y, half_width, half_height; };
struct CollisionWorld { netcode::Tick version = 0; std::vector<Obstacle> obstacles; };
struct Motion { netcode::Object car; float speed = 0; };

enum Action : netcode::MethodId {
    TryOpen = 1, OpenDenied, PlaceBarrier, RemoveBarrier, RoomNotice, Horn
};

class Match {
public:
    using Log = std::function<void(const std::string&)>;
    Match(const Layout& layout, std::unique_ptr<netcode::Transport> transport, bool host,
          netcode::RoomId room = 0, std::optional<netcode::ResumeTicket> ticket = {}, Log log = {},
          std::chrono::nanoseconds network_period = std::chrono::milliseconds(50));

    void update(netcode::TimePoint now);
    bool start(std::size_t objects = 0);
    void end_round();
    void end_room();
    void disconnect();
    void set_input(Input input);
    bool open_gate(bool public_object = false);
    bool barrier(bool create);
    bool horn();
    bool kick(netcode::PlayerId player);
    bool chat(std::string_view text);
    std::vector<netcode::PlayerId> players() const;
    const std::deque<netcode::RoomMessage>& messages() const;
    void freeze(bool frozen);
    bool set_client_authority(netcode::PlayerId player, bool enabled);
    bool toggle_guest_authority(unsigned seat);
    netcode::Object presentation(netcode::ObjectId id);
    netcode::PlayerId state_writer(netcode::ObjectId id) const { return writers_.writer(id); }
    bool predicts(netcode::ObjectId id) const { return prediction_.ready() && id == predicted_car_; }
    const netcode::Prediction<Motion, Input>& local_prediction() const { return prediction_; }
    bool uses_local_state(netcode::ObjectId id) const { return !host_ && (state_writer(id) == player() || predicts(id)); }
    bool buffered(netcode::ObjectId id) const;
    bool grant_car(netcode::ObjectId car, netcode::PlayerId writer);
    bool cycle_driver();
    void enable_profile(bool enabled) { profile_enabled_ = enabled; }
    netcode::ObjectId controlled_car() const;
    std::uint64_t submissions() const { return writers_.submissions(); }
    std::uint64_t acceptances() const { return writers_.acceptances(); }

    netcode::RoomPhase phase() const;
    netcode::RoomId room() const;
    netcode::RoundId round() const;
    netcode::PlayerId player() const;
    netcode::ResumeTicket ticket() const;
    netcode::Reject rejected() const;
    netcode::Disconnect loss() const;
    netcode::Tick tick() const { return tick_; }
    netcode::Tick send_tick() const { return send_tick_; }
    std::uint64_t samples() const { return sample_count_; }
    std::uint64_t changes() const { return authority_.changes(); }
    netcode::ObjectId car() const;
    std::size_t seats() const;
    std::size_t ready_guests() const;
    bool ready() const;
    std::vector<netcode::ObjectId> objects() const;
    const netcode::Object* object(netcode::ObjectId id) const;
    std::uint64_t digest() const;
    const std::string& notice() const { return notice_; }
    netcode::Traffic traffic() const { return link_->traffic(); }
    std::size_t rpc_peak() const { return rpc_.peak_queued(); }
    std::size_t rpc_pending() const { return rpc_.queued(); }
    netcode::Transport& transport() { return *link_; }

private:
    struct Driver {
        netcode::ObjectId object;
        float speed = 0;
        Input input;
        std::uint32_t sequence = 0;
        netcode::Tick last_input = 0;
        bool delegate = false;
        bool prediction = false;
        netcode::Tick consumed = 0;
        std::map<netcode::Tick, Input> inputs;
    };

    void receive(const netcode::Event& event);
    void host_message(const netcode::Event& event, netcode::GameMessage type, netcode::Reader& reader);
    void guest_message(const netcode::Event& event, netcode::GameMessage type, netcode::Reader& reader);
    void receive_rpc(const netcode::RpcCall& call);
    void network_step();
    void simulate();
    void simulate_local_car(netcode::ObjectId id, Input input);
    std::vector<Obstacle> blockers() const;
    void predict_move(Motion& state, Input input, netcode::Tick tick) const;
    void remember_world(netcode::Tick effective);
    void record_world(netcode::Tick effective, CollisionWorld world);
    const CollisionWorld& world_at(netcode::Tick tick) const;
    void send_checkpoint(netcode::Peer peer, const Driver& driver);
    void send_history();
    bool prediction_request(const netcode::Event& event, netcode::GameMessage type, netcode::Reader& in, Driver& driver);
    void receive_checkpoint(netcode::Reader& in);
    void receive_world(netcode::Reader& in);
    void observe_time(netcode::Tick tick);
    void observe(const netcode::Object& object);
    void authority_changed(const netcode::ObjectGrant& grant);
    void begin(std::size_t count);
    void clear_world();
    void log(const std::string& message) const;
    netcode::ObjectId find(netcode::SchemaId schema, netcode::PlayerId owner = 0) const;
    netcode::ObjectId spawn(netcode::SchemaId schema, netcode::PlayerId owner, const netcode::Values& values);

    std::unique_ptr<netcode::Transport> link_;
    std::optional<netcode::RoomHost> host_;
    std::optional<netcode::RoomGuest> guest_;
    netcode::AuthorityState authority_;
    netcode::ReplicaState replica_;
    netcode::Rpc rpc_;
    netcode::ObjectAuthority writers_;
    Log trace_;
    const std::chrono::nanoseconds network_period_;
    std::map<netcode::PlayerId, Driver> drivers_;
    netcode::Prediction<Motion, Input> prediction_;
    netcode::ObjectId predicted_car_ = 0;
    std::map<netcode::Tick, CollisionWorld> worlds_;
    netcode::Tick world_version_ = 0, clock_tick_ = 0;
    netcode::TimePoint frame_time_{}, clock_time_{};
    double render_tick_ = 0;
    std::map<netcode::ObjectId, netcode::SnapshotBuffer> snapshots_;
    struct Display { netcode::Values values; netcode::Tick revision = 0; bool local = false; };
    std::map<netcode::ObjectId, Display> displays_;
    bool prediction_frozen_ = false;
    bool profile_enabled_ = false;
    std::set<netcode::Peer> attached_;
    netcode::ObjectId next_object_ = 1, gate_ = 0, beacon_ = 0;
    netcode::Tick tick_ = 0, send_tick_ = 0;
    std::uint64_t sample_count_ = 0;
    netcode::TimePoint next_simulate_{}, next_network_{};
    std::uint32_t input_sequence_ = 0;
    Input local_;
    std::string notice_;
    bool frozen_ = false;
};

}
