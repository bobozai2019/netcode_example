#include "scene.hpp"
#include "renderer/backend/Device.h"

#include <iostream>
#include <string_view>
#include <vector>

namespace {

class YardApplication final : public cocos2d::Application {
public:
    explicit YardApplication(yard::Options options) : options_(std::move(options)) {}

    void initGLContextAttrs() override
    {
        GLContextAttrs attrs{8, 8, 8, 8, 24, 8, 0};
        cocos2d::GLView::setGLContextAttrs(attrs);
    }

    bool applicationDidFinishLaunching() override
    {
        using namespace cocos2d;
        auto director = Director::getInstance();
        const bool headless = Runtime::isHeadless();
        const auto title = options_.lobby ? "Netcode Car Yard" :
            (options_.host ? "Netcode Car Yard - Host" : "Netcode Car Yard - Guest");
        GLView* view = headless ? GLView::createHeadless(title, Size(960, 640))
                                : GLViewImpl::createWithRect(title, Rect(60, 70, 960, 640));
        if (!view) return false;
        director->setOpenGLView(view);
        if (options_.trace) {
            const auto* info = backend::Device::getInstance()->getDeviceInfo();
            std::cout << "renderer=" << info->getRenderer() << " version=" << info->getVersion() << std::endl;
        }
        view->setDesignResolutionSize(960, 640, ResolutionPolicy::SHOW_ALL);
        director->setAnimationInterval(1.0f / 60.0f);
        if (headless && !options_.lobby_capture.empty()) {
            utils::captureScreen([](bool ok, const std::string&) {
                std::cout << (ok ? "lobby_capture_ok" : "lobby_capture_failed") << std::endl;
            }, options_.lobby_capture.generic_string());
        }
        if (options_.smoke || options_.binding_smoke) {
            auto scene = Scene::create();
            scene->addChild(LayerColor::create(Color4B(29, 39, 46, 255)));
            scene->scheduleOnce([this, scene](float) {
                if (options_.binding_smoke) {
                    const yard::Layout layout(options_.assets / "replicators.cfg");
                    const bool passed = yard::cocos::verify_bindings(layout, *scene);
                    std::cout << "Cocos 2D/3D transform, independent fields, child replacement, deletion "
                              << (passed ? "passed" : "failed") << std::endl;
                    quit(passed ? 0 : 1);
                } else {
                    std::cout << (cocos2d::Runtime::isHeadless() ? "Cocos2d-x scene updated" : "Cocos2d-x scene rendered")
                              << std::endl;
                    quit(0);
                }
            }, 0.5f, "smoke");
            director->runWithScene(scene);
            return true;
        }
        lobby_ = std::make_unique<yard::Lobby>(options_);
        scene_ = yard::cocos::YardScene::create(*lobby_, [this](int status) { quit(status); });
        if (!scene_) return false;
        director->runWithScene(scene_);
        return true;
    }

    void applicationDidEnterBackground() override { if (scene_) scene_->clear_input(); }
    void applicationWillEnterForeground() override {}

    int status() const { return status_; }

private:
    void quit(int status)
    {
        status_ = status;
        scene_ = nullptr;
        cocos2d::Director::getInstance()->end();
    }

    yard::Options options_;
    std::unique_ptr<yard::Lobby> lobby_;
    yard::cocos::YardScene* scene_ = nullptr;
    int status_ = 0;
};

}

int main(int argc, char** argv)
{
    try {
        if (!cocos2d::Runtime::configure(argc, argv)) return 1;
        std::vector<char*> yard_args{argv[0]};
        for (int i = 1; i < argc; ++i) {
            if (std::string_view(argv[i]) != "--headless") yard_args.push_back(argv[i]);
        }
        auto options = yard::parse_options(static_cast<int>(yard_args.size()), yard_args.data());
        if (cocos2d::Runtime::isHeadless()) options.lobby = false;
        YardApplication app(std::move(options));
        const auto error = app.run();
        return error ? error : app.status();
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
