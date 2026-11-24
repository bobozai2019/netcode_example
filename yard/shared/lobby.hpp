#pragma once

#include "runner.hpp"

namespace yard {

class Lobby {
public:
    explicit Lobby(Options options);
    Lobby(Options options, Layout layout);

    const Options& options() const { return options_; }
    const Layout& layout() const { return layout_; }
    const std::string& local_ip() const { return local_ip_; }
    Runner* runner() const { return runner_.get(); }
    void enter(bool host, std::string_view address, std::string_view port);
    void leave();
    std::string endpoint() const;

private:
    Options options_;
    Layout layout_;
    std::string local_ip_;
    std::unique_ptr<Runner> runner_;
};

std::vector<std::uint16_t> available_ports();
std::string connection_status(const Match& match);
std::string player_name(netcode::PlayerId player);

}
