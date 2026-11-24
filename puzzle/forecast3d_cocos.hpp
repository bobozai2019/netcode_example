#pragma once
#include "forecast_body_3d.hpp"
#include "game_component.hpp"
#if CC_USE_3D_PHYSICS
#include "physics3d/CCPhysics3DShape.h"
#include "physics3d/CCPhysics3DWorld.h"
#include <iostream>

class Forecast3DFixture {
  public:
    bool create(std::unique_ptr<netcode::ScriptGame> script) {
        using namespace cocos2d;
        auto scene = Scene::createWithPhysics();
        auto *world = scene->getPhysics3DWorld();
        if (!world)
            return false;
        world->setGravity(Vec3::ZERO);
        Physics3DRigidBodyDes info;
        info.mass = 1;
        info.shape = Physics3DShape::createSphere(.4f);
        auto *moving = Physics3DRigidBody::create(&info);
        moving->setCollisionCallback([this](const Physics3DCollisionInfo &info) {
            contact_ = !info.collisionPointList.empty() || contact_;
        });
        world->addPhysics3DObject(moving);
        body_ = moving->getRigidBody();
        adapter_ = std::make_unique<netcode::cocos::ForecastBody3D>(*moving);
        Physics3DRigidBodyDes wall;
        wall.shape = Physics3DShape::createBox(Vec3(.1f, 2, 3));
        Mat4::createTranslation(3, 0, 0, &wall.originalTransform);
        world->addPhysics3DObject(Physics3DRigidBody::create(&wall));
        net_ = netcode::cocos::GameComponent::create(std::move(script));
        scene->addComponent(net_);
        scene->scheduleUpdate();
        net_->on_frame = [this] { frame(); };
        Director::getInstance()->runWithScene(scene);
        std::cout << "forecast_open engine=cocos" << std::endl;
        return true;
    }

  private:
    void sleep() {
        body_->setLinearVelocity({0, 0, 0});
        body_->setAngularVelocity({0, 0, 0});
        body_->forceActivationState(ISLAND_SLEEPING);
    }
    void frame() {
        using namespace netcode;
        auto &script = net_->game();
        auto &g = script.session();
        if (g.host() && !g.round() && g.host()->members().size() >= 3 && g.start(Clock::now())) {
            body_->activate(true);
            body_->setLinearVelocity({3, 0, .25f});
            g.world().spawn(1, 1, adapter_->sample(0, 0));
        }
        if (!g.round())
            return;
        if (g.host()) {
            auto time = g.clock().seconds();
            if (phase_ == 0 && contact_) {
                phase_ = 1;
                deadline_ = time + .8;
            } else if (phase_ == 1 && time >= deadline_) {
                sleep();
                phase_ = 2;
                deadline_ = time + .6;
            } else if (phase_ == 2 && time >= deadline_) {
                body_->activate(true);
                body_->setCenterOfMassTransform(
                    btTransform(btQuaternion(btVector3(0, 1, 0), .8f), {8, 1, 2}));
                body_->setLinearVelocity({.5f, 0, .2f});
                body_->setAngularVelocity({0, .4f, 0});
                ++generation_;
                phase_ = 3;
                deadline_ = time + .7;
            } else if (phase_ == 3 && time >= deadline_) {
                sleep();
                phase_ = 4;
            }
            script.submit(1, adapter_->sample(generation_, phase_));
        } else {
            const auto *o = g.object(1);
            if (!o)
                return;
            phase_ = std::get<int32_t>(o->values[6]);
            if (o->revision != revision_) {
                using Mode = cocos::ForecastBody3D::Correction;
                adapter_->mode = phase_ < 2 ? Mode::Blend : Mode::Force;
                adapter_->apply(o->values,
                                float(g.clock().seconds() - g.clock().object_time(o->sample_tick)));
                revision_ = o->revision;
            }
        }
        const auto &pose = body_->getCenterOfMassTransform();
        const auto x = pose.getOrigin().x();
        if (trajectory_sample_ < 4 && g.clock().seconds() >= .35 + trajectory_sample_ * .15) {
            std::cout << "forecast_point index=" << trajectory_sample_++ << " x_mm=" << int(x * 1000) << std::endl;
        }
        if (phase_ != logged_) {
            logged_ = phase_;
            std::cout << "forecast_stage phase=" << phase_ << " x=" << x << " contact=" << contact_
                      << " sleep=" << !body_->isActive() << std::endl;
        }
        if (phase_ == 2 && !body_->isActive())
            slept_ = true;
        if (phase_ == 3 && x >= 7.8f && body_->isActive() && body_->getLinearVelocity().x() > 0)
            woke_ = true;
        if (!reported_ && phase_ == 4 && contact_ && slept_ && woke_ && !body_->isActive() && x > 8) {
            const auto forward = pose.getBasis() * btVector3(0, 0, 1);
            std::cout << "forecast_pass engine=cocos contact=1 slept=1 woke=1 final_mm=" << int(x * 1000)
                      << " depth_mm=" << int(pose.getOrigin().z() * 1000)
                      << " heading_mrad=" << int(btAtan2(forward.x(), forward.z()) * 1000) << std::endl;
            reported_ = true;
        }
    }
    btRigidBody *body_{};
    netcode::cocos::GameComponent *net_{};
    std::unique_ptr<netcode::cocos::ForecastBody3D> adapter_;
    int phase_ = 0, generation_ = 0, logged_ = -1;
    uint32_t revision_ = 0;
    double deadline_ = 0;
    int trajectory_sample_ = 0;
    bool contact_ = false, slept_ = false, woke_ = false, reported_ = false;
};
#endif
