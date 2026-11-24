#pragma once

#include "cocos2d.h"
#include "lobby.hpp"
#include "ui/UIButton.h"
#include "ui/UIEditBox/UIEditBox.h"
#include "ui/UIScrollView.h"

namespace yard::cocos {

class LobbyPanel final : public cocos2d::Node {
public:
    static LobbyPanel* create(Lobby& lobby);
    void refresh();

private:
    explicit LobbyPanel(Lobby& lobby) : lobby_(lobby) {}
    void build();
    void refresh_ports();
    void enter(bool host);
    void send_chat();
    void show_chat(const Match& match);

    Lobby& lobby_;
    cocos2d::Node* setup_ = nullptr;
    cocos2d::Node* room_ = nullptr;
    cocos2d::Label *feedback_ = nullptr, *room_feedback_ = nullptr, *room_title_ = nullptr,
                    *endpoint_ = nullptr, *room_status_ = nullptr, *chat_text_ = nullptr;
    cocos2d::ui::EditBox *join_ip_ = nullptr, *join_port_ = nullptr, *host_port_ = nullptr, *chat_input_ = nullptr;
    cocos2d::ui::Button *start_ = nullptr, *send_ = nullptr, *leave_ = nullptr;
    cocos2d::ui::ScrollView* chat_log_ = nullptr;
    std::array<cocos2d::Label*, netcode::room_capacity> players_{};
    std::array<cocos2d::ui::Button*, netcode::room_capacity> kicks_{};
    std::array<cocos2d::ui::Button*, 3> ports_{};
    std::vector<std::uint16_t> port_choices_;
    std::vector<netcode::PlayerId> roster_;
};

}
