#include "game_component.hpp"
#include "session/direct_game.hpp"
#include "forecast_cocos.hpp"
#include "forecast3d_cocos.hpp"
#include "island_cocos.hpp"
#include "components_cocos.hpp"

#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <sstream>
#include <string_view>

namespace {
using namespace netcode;
class PuzzleApplication final : public cocos2d::Application {
  public:
    PuzzleApplication(int argc, char **argv) {
        config_ = std::filesystem::absolute(argv[0]).parent_path() / "plates.cfg";
        options_.extended_join = true;
        options_.admission = {5, true, true};
        direct_.port = 43271;
        for (int i = 1; i < argc; ++i) {
            std::string_view arg = argv[i];
            if (arg == "--components") {
                components_ = true;
                config_.replace_filename("components.cfg");
            } else if (arg == "--authority-reset") {
                allow_reset_ = true;
            } else if (arg == "--physics-island") {
                island_ = true;
                config_.replace_filename("island.cfg");
            } else if (arg == "--forecast3d") {
                native_3d_ = true;
                config_.replace_filename("body3d.cfg");
            } else if (arg == "--forecast") {
                native_physics_ = true;
                config_.replace_filename("body.cfg");
            } else if (arg == "--puzzle-host")
                options_.host = true;
            else if (arg == "--puzzle-auto")
                automatic_ = true;
            else if (arg == "--address" && i + 1 < argc)
                direct_.address = argv[++i];
            else if (arg == "--port" && i + 1 < argc) {
                const auto n = std::stoul(argv[++i]);
                if (!n || n > 65535)
                    throw std::invalid_argument("port");
                direct_.port = static_cast<uint16_t>(n);
            }
        }
    }
    bool applicationDidFinishLaunching() override {
        using namespace cocos2d;
        auto director = Director::getInstance();
        GLView *view = Runtime::isHeadless()
                           ? GLView::createHeadless("Pressure plates", Size(720, 360))
                           : GLViewImpl::createWithRect("Pressure plates", Rect(50, 50, 720, 360));
        if (!view)
            return false;
        director->setOpenGLView(view);
        director->setAnimationInterval(1.0f / 60);
        auto scene = Scene::create();
        ReplicationLayout layout(config_);
        auto game = open_direct_game(direct_, options_, layout);
        if (native_3d_ || island_) {
#if CC_USE_3D_PHYSICS
            if (island_) return island_fixture_.create(std::move(game), allow_reset_);
            return fixture_3d_.create(std::move(game));
#else
            throw std::runtime_error("Build with --bullet-root to enable Cocos 3D physics");
#endif
        }
        if (native_physics_ || components_) {
#if CC_USE_PHYSICS
            if (components_) return components_fixture_.create(std::move(game));
            return fixture_.create(std::move(game));
#else
            throw std::runtime_error("Build with --chipmunk-root to enable native Cocos physics");
#endif
        }
        if (!game->model(1, {1}, ClaimMode::Transaction, 0) ||
            !game->register_rpc(31, int(Direction::Server), true, 1, true, false))
            return false;
        if (!game->prediction(
                2, {1, 1, {0}, [](Values &fields, const Bytes &input, Tick) {
                        std::get<int32_t>(fields[0]) += input[0];
                        return true;
                    }}))
            return false;
        if (options_.host)
            game->set_player_ttl(15000);
        component_ = netcode::cocos::GameComponent::create(std::move(game));
        component_->setName("Network");
        scene->addComponent(component_);
        scene->scheduleUpdate();
        label_ = Label::createWithSystemFont("Waiting for players", "Arial", 24);
        label_->setPosition(360, 305);
        scene->addChild(label_);
        for (int i = 0; i < 2; ++i) {
            auto marker =
                LayerColor::create(i ? Color4B(87, 205, 170, 255) : Color4B(247, 157, 106, 255), 36, 30);
            marker->setPosition(110, 200 - i * 65);
            scene->addChild(marker, 1);
            markers_[i] = marker;
            auto target = LayerColor::create(Color4B(120, 137, 149, 255), 42, 36);
            target->setPosition(107 + (i ? 7 : 3) * 65, 197 - i * 65);
            scene->addChild(target);
        }
        auto keyboard = EventListenerKeyboard::create();
        keyboard->onKeyPressed = [this](EventKeyboard::KeyCode key, cocos2d::Event *) {
            if (key == EventKeyboard::KeyCode::KEY_SPACE)
                want_move_ = true;
        };
        director->getEventDispatcher()->addEventListenerWithSceneGraphPriority(keyboard, scene);
        component_->on_event = [this](const netcode::ScriptEvent &e) {
            auto &world = component_->game().session().world();
            if (e.kind == ScriptEventKind::MapAdded && world.maps().at(e.object).asset == "plates") {
                const auto scene = e.object, generation = e.epoch;
                generations_[scene] = generation;
                const auto path = (config_.parent_path() / "plate-room.txt").string();
                cocos2d::FileUtils::getInstance()->getStringFromFile(
                    path, [this, scene, generation](std::string data) {
                        auto current = generations_.find(scene);
                        if (current == generations_.end() || current->second != generation ||
                            (automatic_ && scene == 2 && generation == 2))
                            return;
                        std::istringstream resource(data);
                        std::string name;
                        float x, y;
                        if (!(resource >> name >> x >> y) || name != "PlateAnchor")
                            return;
                        auto room = cocos2d::Node::create();
                        auto marker = cocos2d::Node::create();
                        marker->setName(name);
                        marker->setPosition(x, y);
                        room->addChild(marker);
                        component_->getOwner()->addChild(room);
                        mounted_[scene] = room;
                        if (!options_.host)
                            component_->game().session().world().loaded(scene, generation);
                        if (room->getChildByName("PlateAnchor"))
                            std::cout << "map_mounted scene=" << scene << " generation=" << generation
                                      << " anchors=1" << std::endl;
                    });
            } else if (e.kind == ScriptEventKind::MapRemoved) {
                generations_.erase(e.object);
                auto node = mounted_.find(e.object);
                if (node != mounted_.end()) {
                    node->second->removeFromParent();
                    mounted_.erase(node);
                    std::cout << "map_removed";
                } else
                    std::cout << "map_cancel";
                std::cout << " scene=" << e.object << " generation=" << e.epoch << std::endl;
            }
            if (!ack_reported_ && e.kind == ScriptEventKind::Reconciled && e.object == 3 && e.sequence == 1) {
                ack_reported_ = true;
                std::cout << "charge_ack sequence=1" << std::endl;
            }
            if (e.kind == ScriptEventKind::Request)
                component_->game().answer({e.object, e.player, e.epoch, e.sequence}, true);
            if (e.kind == ScriptEventKind::Result && e.status)
                claimed_ = false;
        };
        component_->on_frame = [this] { frame(); };
        director->runWithScene(scene);
        std::cout << "puzzle_open engine=cocos host=" << options_.host << std::endl;
        return true;
    }
    void applicationDidEnterBackground() override {}
    void applicationWillEnterForeground() override {}

  private:
    void frame() {
        auto &script = component_->game();
        auto &g = script.session();
        for (const auto& result : g.rpc().take_outcomes())
            if (result.method == 31 && result.status == RpcStatus::Received)
                std::cout << "plate_ack token=" << result.token << " player=" << result.player << std::endl;
        while (const auto *call = script.next_rpc()) {
            if (call->method == 31 && call->arguments.size() == 1)
                std::cout << "plate_action player=" << call->sender << " object=" << call->object
                          << " value=" << unsigned(call->arguments[0]) << std::endl;
            script.pop_rpc();
        }
        if (options_.host && !g.round() && g.host()->members().size() >= 3 && g.start(Clock::now())) {
            g.world().load_map(1, "plates");
            g.world().spawn(1, 1, {int32_t(0), std::string("Amber"), int32_t(3200)}, {1, 100});
            g.world().spawn(1, 1, {int32_t(0), std::string("Jade"), int32_t(3200)},
                            {1, 200, 0, ClaimMode::Dynamic});
            auto meter = g.world().spawn(2, 1, {int32_t(0)}, {1, 300});
            script.distribute(meter, InterestKind::Area, {81}, 1);
            for (auto member : {2, 3})
                script.subscribe(member, InterestKind::Area, {81}, {1});
            g.prediction().bind(meter, 2);
        }
        if (options_.host && automatic_ && g.round()) {
            const auto time = g.clock().seconds();
            if (map_phase_ == 0 && time > .45) {
                g.world().load_map(2, "plates");
                ++map_phase_;
            } else if (map_phase_ == 1 && time > 1.25) {
                g.world().unload_map(2);
                g.world().load_map(2, "plates");
                ++map_phase_;
            } else if (map_phase_ == 2 && time > 2.4) {
                g.world().unload_map(2);
                ++map_phase_;
            }
        }
        const auto player = g.local();
        if (automatic_ && player == 2 && !input_sent_ && g.prediction().advance(3, {5})) {
            input_sent_ = true;
            if (std::get<int32_t>(g.prediction().state(3)->front()) == 5)
                std::cout << "charge_predicted value=5" << std::endl;
        }
        auto meter = g.object(3);
        if (!charge_reported_ && meter && std::get<int32_t>(meter->values[0]) == 5) {
            charge_reported_ = true;
            std::cout << "charge_confirmed value=5" << std::endl;
        }
        if ((automatic_ || want_move_) && (player == 2 || player == 3)) {
            const auto id = player - 1;
            if (g.writers().writer(id) != player) {
                if (!claimed_)
                    claimed_ = g.writers().request(id);
            } else if (!submitted_)
                submitted_ = script.submit(id, {int32_t(id == 1 ? 3 : 7)});
            if (submitted_ && !command_sent_)
                command_sent_ = g.rpc().invoke(id, 31, {uint8_t(id == 1 ? 3 : 7)},0,id);
        }
        bool aligned = true;
        for (int i = 0; i < 2; ++i) {
            Values fields;
            if (!script.read(g.world().find(1, (i + 1) * 100), false, fields))
                return;
            const auto deadline = std::get<int32_t>(fields[2]);
            if (!clock_reported_ && g.clock().seconds() * 1000 >= deadline) {
                clock_reported_ = true;
                std::cout << "countdown_reached deadline_ms=" << deadline
                          << " observed_ms=" << int(g.clock().seconds() * 1000) << std::endl;
            }
            const auto pos = std::get<int32_t>(fields[0]);
            markers_[i]->setPositionX(110 + 65.f * pos);
            aligned = aligned && pos == (i ? 7 : 3) &&
                      std::get<std::string>(fields[1]) == (i ? "Jade" : "Amber") &&
                      g.writers().writer(i + 1) == unsigned(i + 2);
        }
        if (!solved_ && aligned) {
            solved_ = true;
            std::cout << "puzzle_solved engine=cocos player=" << player << " first=2 second=3" << std::endl;
        }
        label_->setString(solved_         ? "Both plates aligned"
                          : options_.host ? "Waiting for both players"
                                          : "Space to move your plate");
    }
    std::map<SceneId, uint32_t> generations_;
    std::map<SceneId, cocos2d::Node *> mounted_;
    int map_phase_ = 0;
    std::filesystem::path config_;
    SessionOptions options_;
#if CC_USE_3D_PHYSICS
    IslandFixture island_fixture_;
    Forecast3DFixture fixture_3d_;
#endif
    bool components_ = false, allow_reset_ = false, island_ = false, native_3d_ = false, native_physics_ = false, clock_reported_ = false;
#if CC_USE_PHYSICS
    GameplayFixture components_fixture_;
    ForecastFixture fixture_;
#endif
    DirectConfig direct_;
    netcode::cocos::GameComponent *component_ = nullptr;
    cocos2d::Label *label_ = nullptr;
    cocos2d::Node *markers_[2]{};
    bool command_sent_ = false, ack_reported_ = false, input_sent_ = false, charge_reported_ = false;
    bool automatic_ = false, want_move_ = false, claimed_ = false, submitted_ = false, solved_ = false;
};
} // namespace
int main(int argc, char **argv) {
    try {
        if (!cocos2d::Runtime::configure(argc, argv))
            return 1;
        PuzzleApplication app(argc, argv);
        return app.run();
    } catch (const std::exception &e) {
        std::cerr << e.what() << std::endl;
        return 1;
    }
}
