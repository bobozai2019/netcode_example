#pragma once
#include "game_component.hpp"
#include "physics_island_3d.hpp"
#if CC_USE_3D_PHYSICS
#include "physics3d/CCPhysics3DConstraint.h"
#include "physics3d/CCPhysics3DShape.h"
#include "physics3d/CCPhysics3DWorld.h"
#include <iostream>

class IslandFixture {
    struct Group {
        cocos2d::Physics3DWorld *world;
        netcode::cocos::PhysicsIsland3D island;
        std::array<cocos2d::Physics3DRigidBody *, 4> bodies;
        cocos2d::Physics3DRigidBody *box(cocos2d::Vec3 pos, cocos2d::Vec3 size, float mass) {
            cocos2d::Physics3DRigidBodyDes info;
            info.mass = mass;
            info.shape = cocos2d::Physics3DShape::createBox(size);
            cocos2d::Mat4::createTranslation(pos, &info.originalTransform);
            auto body = cocos2d::Physics3DRigidBody::create(&info);
            world->addPhysics3DObject(body);
            return body;
        }
        Group() {
            using namespace cocos2d;
            Physics3DWorldDes info;
            world = Physics3DWorld::create(&info);
            box({0, -.5f, 0}, {20, 1, 20}, 0);
            for (int i = 0; i < 4; ++i) {
                auto pos = i < 2 ? Vec3(0, .5f + i, 0) : Vec3(float(i), 1, 0);
                bodies[i] = box(pos, {1, 1, 1}, 1);
                bodies[i]->getRigidBody()->setSleepingThresholds(0, 0);
                if (!island.add(i + 1, *bodies[i]))
                    throw std::runtime_error("island body");
            }
            Mat4 a, b;
            Mat4::createTranslation(.5f, 0, 0, &a);
            Mat4::createTranslation(-.5f, 0, 0, &b);
            auto joint = Physics3D6DofConstraint::create(bodies[2], bodies[3], a, b, true);
            joint->setLinearLowerLimit(Vec3::ZERO);
            joint->setLinearUpperLimit(Vec3::ZERO);
            joint->setAngularLowerLimit(Vec3::ZERO);
            joint->setAngularUpperLimit(Vec3::ZERO);
            world->addPhysics3DConstraint(joint, true);
        }
        void advance(int first, int last, bool disturb = false) {
            for (int tick = first; tick <= last; ++tick) {
                if (tick == 41)
                    bodies[3]->getRigidBody()->applyImpulse({0, 2, 0}, {.35f, 0, 0});
                if (tick == 48) {
                    bodies[1]->getRigidBody()->applyCentralImpulse({.8f, 1.4f, .3f});
                    bodies[3]->getRigidBody()->applyImpulse({0, 2, 0}, {.4f, 0, 0});
                    if (disturb)
                        bodies[0]->getRigidBody()->applyCentralImpulse({-3, 0, 0});
                }
                world->stepSimulate(1.f / 60);
            }
        }
    };
    static btVector3 pos(const netcode::Values &fields, int index) {
        auto p = std::get<netcode::FloatArray>(fields.at(3)).data() + index * 13;
        return {p[0], p[1], p[2]};
    }
    static float error(const netcode::Values &a, const netcode::Values &b) {
        float d = 0;
        for (int i = 0; i < 4; ++i)
            d = std::max(d, pos(a, i).distance(pos(b, i)));
        return d;
    }
    netcode::cocos::GameComponent *component_{};
    bool sent_ = false, allow_reset_ = false;
    netcode::TimePoint exit_at_{};
    void frame() {
        using namespace netcode;
        auto &script = component_->game();
        auto &g = script.session();
        if (g.host()) {
            if (!sent_ && g.host()->members().size() == 2 && g.start(Clock::now())) {
                Group author;
                author.advance(1, 45);
                auto checkpoint = author.island.capture(45);
                author.advance(46, 70);
                if (g.world().spawn(1, g.local(), checkpoint) != 1 ||
                    g.world().spawn(1, g.local(), author.island.capture(70)) != 2)
                    throw std::runtime_error("island spawn");
                sent_ = true;
            }
            while (auto call = script.next_rpc()) {
                if (call->method == 45 && call->sender == 2 && call->arguments == Bytes{70}) {
                    std::cout << "island_confirmed" << std::endl;
                    cocos2d::Director::getInstance()->end();
                }
                script.pop_rpc();
            }
            return;
        }
        if (sent_) {
            if (Clock::now() >= exit_at_)
                cocos2d::Director::getInstance()->end();
            return;
        }
        Values cp, live;
        if (!script.read(1, false, cp) || !script.read(2, false, live))
            return;
        Group predicted, corrected, reference;
        predicted.advance(1, 70, true);
        if (corrected.island.restore({int32_t(45), IntArray{}, IntArray{}, FloatArray{}}) ||
            !corrected.island.restore(cp) || !reference.island.restore(cp))
            throw std::runtime_error("island restore");
        corrected.advance(46, 70);
        reference.advance(46, 70);
        auto result = corrected.island.capture(70);
        float before = error(live, predicted.island.capture(70)), after = error(live, result);
        float cold = error(result, reference.island.capture(70)),
              gap = std::abs(pos(result, 2).distance(pos(result, 3)) - 1.f);
        auto p = std::get<FloatArray>(cp[3]).data() + 46;
        std::cout << "island_measure before=" << before << " after=" << after << " cold=" << cold
                  << " gap=" << gap << " stack_height=" << pos(cp,1).y()-pos(cp,0).y() << " speed=" << btVector3(p[0],p[1],p[2]).length() << std::endl;
        const bool reset = allow_reset_ && after >= .06f;
        if (reset && !corrected.island.restore(live)) throw std::runtime_error("island final restore");
        const float final = reset ? error(live,corrected.island.capture(70)) : after;
        if (!(btVector3(p[0], p[1], p[2]).length() > .1f && std::get<int32_t>(cp[0]) == 45 &&
              std::get<int32_t>(live[0]) == 70 && before > .1f && final < (reset ? .001f : .06f) && cold < .001f &&
              gap < .025f && pos(cp, 1).y() - pos(cp, 0).y() > .95f))
            throw std::runtime_error("island replay tolerance");
        std::cout << "island_pass bodies=4 checkpoint=45 steps=25 before_mm=" << before * 1000
                  << " after_mm=" << after * 1000 << " cold_mm=" << cold * 1000 << " reset=" << reset << " final_mm=" << final * 1000 << " joint_mm=" << gap * 1000
                  << std::endl;
        if (!g.rpc().invoke(0, 45, Bytes{70}))
            throw std::runtime_error("island confirmation");
        sent_ = true;
        exit_at_ = Clock::now() + std::chrono::seconds(1);
    }

  public:
    bool create(std::unique_ptr<netcode::ScriptGame> game, bool allow_reset) {
        allow_reset_ = allow_reset;
        if (!game->register_rpc(45, int(netcode::Direction::Server), true, 1, false, true))
            return false;
        auto scene = cocos2d::Scene::create();
        component_ = netcode::cocos::GameComponent::create(std::move(game));
        component_->on_frame = [this] { frame(); };
        scene->addComponent(component_);
        scene->scheduleUpdate();
        cocos2d::Director::getInstance()->runWithScene(scene);
        std::cout << "island_open" << std::endl;
        return true;
    }
};
#endif
