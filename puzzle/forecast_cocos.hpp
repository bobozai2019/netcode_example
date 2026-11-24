#pragma once
#include "forecast_body.hpp"
#include "game_component.hpp"
#if CC_USE_PHYSICS
#include "chipmunk/chipmunk.h"
#include <iostream>

class ForecastFixture {
  public:
    bool create(std::unique_ptr<netcode::ScriptGame> game) {
        using namespace cocos2d;
        auto scene = Scene::createWithPhysics();
        scene->getPhysicsWorld()->setGravity(Vec2::ZERO);
        auto node = Node::create();
        body_ = PhysicsBody::createCircle(20, PhysicsMaterial(1, 0, 0));
        body_->setContactTestBitmask(-1);
        node->setPhysicsBody(body_);
        scene->addChild(node);
        node_ = node;
        forecast_ = std::make_unique<netcode::cocos::ForecastBody>(*node, 50.f);
        auto wall = Node::create();
        auto fixed = PhysicsBody::createBox({10, 200}, PhysicsMaterial(1, 0, 0));
        fixed->setDynamic(false);
        fixed->setContactTestBitmask(-1);
        wall->setPhysicsBody(fixed);
        wall->setPosition(150, 0);
        scene->addChild(wall);
        auto listener = EventListenerPhysicsContact::create();
        listener->onContactBegin = [this](PhysicsContact&) {
            contact_ = true;
            return true;
        };
        Director::getInstance()->getEventDispatcher()->addEventListenerWithSceneGraphPriority(listener,
                                                                                              scene);
        component_ = netcode::cocos::GameComponent::create(std::move(game));
        component_->setName("Network");
        scene->addComponent(component_);
        scene->scheduleUpdate();
        component_->on_frame = [this] { frame(); };
        Director::getInstance()->runWithScene(scene);
        std::cout << "forecast_open engine=cocos" << std::endl;
        return true;
    }

  private:
    void frame() {
        auto& script = component_->game();
        auto& g = script.session();
        if (g.host() && !g.round() && g.host()->members().size() >= 3 && g.start(netcode::Clock::now())) {
            body_->setVelocity({150, 0});
            g.world().spawn(1, 1, forecast_->sample(0, 0));
        }
        if (!g.round())
            return;
        auto space = cpBodyGetSpace(body_->getCPBody());
        if (!space)
            return;
        cpSpaceSetSleepTimeThreshold(space, 10);
        netcode::Values fields;
        if (g.host()) {
            auto now = g.clock().seconds();
            if (!phase_ && contact_) {
                phase_ = 1;
                deadline_ = now + .8;
            } else if (phase_ == 1 && now >= deadline_) {
                body_->setVelocity({0, 0});
                body_->setResting(true);
                phase_ = 2;
                deadline_ = now + .6;
            } else if (phase_ == 2 && now >= deadline_) {
                body_->setResting(false);
                node_->setPosition(400, 0);
                body_->setVelocity({25, 0});
                ++generation_;
                phase_ = 3;
                deadline_ = now + .7;
            } else if (phase_ == 3 && now >= deadline_) {
                body_->setVelocity({0, 0});
                body_->setResting(true);
                phase_ = 4;
            }
            fields = forecast_->sample(generation_, phase_);
            script.submit(1, fields);
        } else {
            const auto* object = g.object(1);
            if (!object || !script.read(1, false, fields))
                return;
            if (revision_ != object->revision) {
                using Correction = netcode::cocos::ForecastBody::Correction;
                forecast_->mode = std::get<int32_t>(fields[6]) < 2 ? Correction::Blend : Correction::Force;
                forecast_->max_forecast = .25f;
                forecast_->apply(fields,
                                 float(g.clock().seconds() - g.clock().object_time(object->sample_tick)));
                revision_ = object->revision;
            }
            phase_ = std::get<int32_t>(fields[6]);
        }
        const float x = node_->getPositionX() / 50;
        if (trajectory_sample_ < 4 && g.clock().seconds() >= .35 + trajectory_sample_ * .15) {
            std::cout << "forecast_point index=" << trajectory_sample_++ << " x_mm=" << int(x * 1000) << std::endl;
        }
        if (phase_ != logged_) {
            std::cout << "forecast_stage phase=" << phase_ << " x=" << x << " sleep=" << body_->isResting()
                      << " contact=" << contact_ << std::endl;
            logged_ = phase_;
        }
        if (phase_ == 2 && body_->isResting())
            slept_ = true;
        if (phase_ == 3 && x >= 7.8f && !body_->isResting() && body_->getVelocity().x > 0)
            woke_ = true;
        if (!reported_ && contact_ && slept_ && woke_ && phase_ == 4 && body_->isResting() && x > 8) {
            reported_ = true;
            std::cout << "forecast_pass engine=cocos contact=1 slept=1 woke=1 final_mm=" << int(x * 1000)
                      << std::endl;
        }
    }
    netcode::cocos::GameComponent* component_{};
    cocos2d::Node* node_{};
    cocos2d::PhysicsBody* body_{};
    std::unique_ptr<netcode::cocos::ForecastBody> forecast_;
    int32_t phase_ = 0, generation_ = 0, logged_ = -1;
    uint32_t revision_ = 0;
    double deadline_ = 0;
    int trajectory_sample_ = 0;
    bool contact_ = false, slept_ = false, woke_ = false, reported_ = false;
};
#endif
