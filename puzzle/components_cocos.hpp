#pragma once
#include "replica_component.hpp"
#include "build_info.hpp"
#include <iostream>

#if CC_USE_3D_PHYSICS
#include "physics3d/CCPhysics3DShape.h"
#include "physics3d/CCPhysics3DWorld.h"
#endif
#if CC_USE_PHYSICS
class GameplayFixture {
    using Replica = netcode::cocos::ReplicaComponent;
    netcode::cocos::GameComponent *network_{};
    Replica *panel_{}, *motion_{};
    cocos2d::Node *moving_{};
    int32_t score_ = 0;
    netcode::Vector4 weights_{};
    netcode::Color tint_{{0, 0, 0, 1}};
    netcode::ObjectReference selected_;
    netcode::Bytes badge_;
    netcode::Vector2Array route_;
    netcode::IntMap scores_;
    netcode::IntLinkedList queue_;
    bool host_ = false, seeded_ = false, claimed_ = false, received_ = false, reported_ = false;
    netcode::TimePoint finish_{}, next_diagnostic_ = netcode::Clock::now()+std::chrono::seconds(3);
#if CC_USE_3D_PHYSICS
    Replica *motion3_{};
    btRigidBody *body3_{};
#endif
    netcode::TimePoint next_claim_{};
    static netcode::Values args() { return {int32_t(42), std::string("ready"), netcode::Vector2{2, -3}}; }
    void frame() {
        using namespace netcode;
        auto &script = network_->game();
        auto &g = script.session();
        if (Clock::now() >= next_diagnostic_) {
            std::cout << "component_state round=" << g.round() << " panel=" << panel_->initialized()
                      << " rigid2=" << motion_->initialized() << " px=" << moving_->getPositionX()
                      << " score=" << score_ << " writer=" << g.writers().writer(1)
                      << " ref=" << selected_.value << " resolved=" << (network_->resolve_node(selected_) == moving_)
                      << " claimed=" << claimed_ << " reported=" << reported_
#if CC_USE_3D_PHYSICS
                      << " rigid3=" << motion3_->initialized() << " z=" << body3_->getCenterOfMassTransform().getOrigin().z()
#endif
                      << std::endl;
            next_diagnostic_=Clock::now()+std::chrono::seconds(5);
        }
        if (finish_ != TimePoint{}) {
            if (Clock::now() >= finish_)
                cocos2d::Director::getInstance()->end();
            return;
        }
        if (host_ && !g.round() && g.host()->members().size() == 2 && g.start(Clock::now())) {
            if (g.world().spawn(1, g.local(),
                                {score_, weights_, tint_, selected_, badge_, route_, scores_, queue_}) != 1 ||
                g.world().spawn(3, g.local(),
                                {Vector2{}, 0.f, Vector2{}, 0.f, false, int32_t(0), int32_t(0)}) != 2)
                throw std::runtime_error("spawn");
#if CC_USE_3D_PHYSICS
            if (g.world().spawn(4, g.local(),
                                {Vector3{}, Rotation{0, 0, 0, 1}, Vector3{}, Vector3{}, false, int32_t(0),
                                 int32_t(0)}) != 3)
                throw std::runtime_error("3D spawn");
#endif
        }
#if CC_USE_3D_PHYSICS
        if (!motion3_->initialized())
            return;
#endif
        if (!panel_->initialized() || !motion_->initialized())
            return;
        if (host_) {
            if (!seeded_) {
                score_ = 7;
                weights_ = Vector4{{2, 3, 4, 5}};
                tint_ = Color{{.25f, .5f, .75f, 1}};
                selected_ = motion_->reference();
                badge_ = {0, 255, 7};
                route_ = {{2, -3}};
                scores_ = {{-3, 16777219}, {4, 42}};
                queue_ = {5, 5, -1};
#if CC_USE_3D_PHYSICS
                auto pose = body3_->getCenterOfMassTransform();
                pose.setOrigin(btVector3(0, 0, 3));
                body3_->setCenterOfMassTransform(pose);
                body3_->activate(true);
                ++motion3_->teleport_generation;
#endif
                moving_->setPositionX(200);
                ++motion_->teleport_generation;
                seeded_ = true;
            }
            if (received_ && score_ == 42) {
                if (!script.call_method("Done", 0, {}, 2))
                    throw std::runtime_error("reply");
                std::cout << "components_pass role=host score=42 fields=8 body=1 reference=1 typed=1 body3d="
                          << int(CC_USE_3D_PHYSICS) << std::endl;
                finish_ = Clock::now() + std::chrono::seconds(1);
            }
        } else {
#if CC_USE_3D_PHYSICS
            if (std::abs(body3_->getCenterOfMassTransform().getOrigin().z() - 3.f) >= .02f)
                return;
#endif
            if (!claimed_ && Clock::now()>=next_claim_ && score_ == 7 && weights_ == Vector4{{2, 3, 4, 5}} &&
                tint_ == Color{{.25f, .5f, .75f, 1}} && network_->resolve_node(selected_) == moving_ &&
                badge_ == Bytes{0, 255, 7} && route_ == Vector2Array{{2, -3}} &&
                scores_ == IntMap{{-3, 16777219}, {4, 42}} && queue_ == IntLinkedList{5, 5, -1} &&
                std::abs(moving_->getPositionX() - 200) < 1) {
                if (script.call_method("Report", 1, args()))
                    throw std::runtime_error("writer gate");
                claimed_ = g.writers().request(1);
            }
            if (claimed_ && g.writers().writer(1) == g.local()) {
                score_ = 42;
                auto obj = g.object(1);
                if (!reported_ && obj && std::get<int32_t>(obj->values[0]) == 42) {
                    if (script.call_method("Report", 1, {int32_t(42), std::string(17, 'X'), Vector2{}}) ||
                        script.call_method("Report", 1, {std::string("wrong")}))
                        throw std::runtime_error("argument gate");
                    reported_ = script.call_method("Report", 1, args());
                }
            }
        }
    }

  public:
    bool create(std::unique_ptr<netcode::ScriptGame> script) {
        using namespace netcode;
        host_ = script->session().host() != nullptr;
        if (!script->model(1, {1}, ClaimMode::Transaction, 0))
            return false;
        auto scene = cocos2d::Scene::createWithPhysics();
        scene->getPhysicsWorld()->setGravity(cocos2d::Vec2::ZERO);
        network_ = cocos::GameComponent::create(std::move(script));
        scene->addComponent(network_);
        scene->scheduleUpdate();
        if (!network_->bind_callable<int32_t, std::string, Vector2>(
                "Report", 71, 2, Direction::Server, true,
                [this](PlayerId from, ObjectId id, int32_t total, const std::string &label,
                       const Vector2 &spot) {
                    if (!host_ || from != 2 || id != 1 || total != 42 || label != "ready" ||
                        spot != Vector2{2, -3} || received_)
                        throw std::runtime_error("unexpected report");
                    received_ = true;
                },
                true) ||
            !network_->bind_callable(
                "Done", 72, 0, Direction::Client, true,
                [this](PlayerId from, ObjectId id) {
                    if (host_ || from != 1 || id != 0 || !reported_)
                        throw std::runtime_error("unexpected reply");
                    std::cout
                        << "components_pass role=guest score=42 fields=8 body=1 reference=1 typed=1 body3d="
                        << int(CC_USE_3D_PHYSICS) << std::endl;
                    finish_ = netcode::Clock::now();
                },
                false, true))
            return false;
        auto node = cocos2d::Node::create();
        scene->addChild(node);
        panel_ = Replica::attach(*node, *network_, 1);
        if (!panel_)
            return false;
        panel_->member(score_);
        panel_->member(weights_);
        panel_->member(tint_);
        panel_->member(selected_);
        panel_->member(badge_);
        panel_->member(route_);
        panel_->member(scores_);
        panel_->member(queue_);
        moving_ = cocos2d::Node::create();
        moving_->setPhysicsBody(cocos2d::PhysicsBody::createCircle(10));
        scene->addChild(moving_);
        motion_ = Replica::attach(*moving_, *network_, 2);
        if (!motion_)
            return false;
        motion_->teleport_distance = 1;
#if CC_USE_3D_PHYSICS
        auto *world3 = scene->getPhysics3DWorld();
        if (!world3)
            return false;
        world3->setGravity(cocos2d::Vec3::ZERO);
        cocos2d::Physics3DRigidBodyDes config;
        config.mass = 1;
        config.shape = cocos2d::Physics3DShape::createSphere(.4f);
        auto *rigid = cocos2d::Physics3DRigidBody::create(&config);
        world3->addPhysics3DObject(rigid);
        body3_ = rigid->getRigidBody();
        auto *node3 = cocos2d::Node::create();
        scene->addChild(node3);
        motion3_ = Replica::attach(*node3, *network_, 3);
        if (!motion3_)
            return false;
        motion3_->use_body_3d(*rigid);
        motion3_->teleport_distance = 1;
#endif
        network_->on_event = [this](const ScriptEvent &e) {
            if (e.kind == ScriptEventKind::Request)
                network_->game().answer({e.object, e.player, e.epoch, e.sequence}, true);
            if (e.kind == ScriptEventKind::Result && e.object==1 && !host_ && e.status!=unsigned(ClaimStatus::Granted)) {
                std::cout << "claim_result status=" << e.status << std::endl;
                if (e.status!=unsigned(ClaimStatus::Unavailable)) throw std::runtime_error("claim rejected");
                claimed_=false;
                next_claim_=Clock::now()+std::chrono::milliseconds(250);
            }
        };
        network_->on_frame = [this] { frame(); };
        cocos2d::Director::getInstance()->runWithScene(scene);
        std::cout << "sdk_build_id=" << netcode::core_build_id() << "/" << netcode::cocos::GameComponent::platform_build_id() << std::endl;
        std::cout << "components_open" << std::endl;
        return true;
    }
};
#endif
