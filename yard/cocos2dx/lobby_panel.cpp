#include "lobby_panel.hpp"

#include <algorithm>

namespace yard::cocos {
namespace {

using namespace cocos2d;
using namespace cocos2d::ui;
using netcode::RoomPhase;
const Color4B ink{228, 239, 240, 255}, muted{166, 187, 191, 255}, accent{97, 224, 189, 255},
    warning{255, 205, 130, 255}, surface{25, 43, 53, 255}, input{12, 29, 38, 255};

void panel(Node& parent, const Rect& bounds, Color4B color, int z = 0)
{
    auto* paint = DrawNode::create();
    paint->drawSolidRect(bounds.origin, {bounds.getMaxX(), bounds.getMaxY()}, Color4F(color));
    parent.addChild(paint, z);
}

Label* label(Node& parent, const std::string& text, Vec2 position, float size, Color4B color = ink)
{
    auto* node = Label::createWithSystemFont(text, "Segoe UI", size);
    node->setAnchorPoint({0, 0.5f});
    node->setPosition(position);
    node->setTextColor(color);
    parent.addChild(node);
    return node;
}

Button* button(Node& parent, const Rect& bounds, const std::string& text, const std::function<void()>& action,
               bool primary = false)
{
    auto* node = Button::create();
    node->ignoreContentAdaptWithSize(false);
    node->setContentSize(bounds.size);
    node->setAnchorPoint(Vec2::ZERO);
    node->setPosition(bounds.origin);
    panel(*node, {Vec2::ZERO, bounds.size}, primary ? Color4B(36, 86, 78, 255) : Color4B(37, 62, 74, 255), -1);
    node->setTitleFontName("Segoe UI");
    node->setTitleFontSize(16);
    node->setTitleText(text);
    node->setTitleColor(Color3B(primary ? accent : ink));
    node->addClickEventListener([action](Ref*) { action(); });
    parent.addChild(node);
    return node;
}

EditBox* edit(Node& parent, const Rect& bounds, const char* text, int max_length)
{
    panel(parent, bounds, input);
    auto* field = EditBox::create(bounds.size, "");
    field->setAnchorPoint(Vec2::ZERO);
    field->setPosition(bounds.origin);
    field->setInputMode(EditBox::InputMode::SINGLE_LINE);
    field->setFont("Segoe UI", 17);
    field->setFontColor(ink);
    field->setPlaceholderFont("Segoe UI", 17);
    field->setPlaceholderFontColor(muted);
    field->setMaxLength(max_length);
    field->setText(text);
    parent.addChild(field);
    return field;
}

}

LobbyPanel* LobbyPanel::create(Lobby& lobby)
{
    auto* panel = new LobbyPanel(lobby);
    if (!panel->init()) {
        delete panel;
        return nullptr;
    }
    panel->build();
    panel->autorelease();
    return panel;
}

void LobbyPanel::build()
{
    panel(*this, {0, 0, 960, 640}, {14, 26, 34, 255});
    label(*this, "CAR YARD  /  COCOS2D-X", {48, 592}, 14, accent);
    setup_ = Node::create();
    addChild(setup_);
    label(*setup_, "Multiplayer", {48, 544}, 42);
    panel(*setup_, {48, 114, 410, 350}, surface);
    panel(*setup_, {478, 114, 434, 350}, surface);
    label(*setup_, "Join a room", {74, 421}, 25);
    label(*setup_, "Host a room", {504, 421}, 25);
    label(*setup_, "Host IPv4", {74, 366}, 15, muted);
    join_ip_ = edit(*setup_, {74, 313, 358, 40}, "127.0.0.1", 15);
    label(*setup_, "Host port", {74, 290}, 15, muted);
    join_port_ = edit(*setup_, {74, 238, 358, 40}, "", 5);
    label(*setup_, "Local IPv4", {504, 366}, 15, muted);
    panel(*setup_, {504, 313, 382, 40}, input);
    label(*setup_, lobby_.local_ip(), {515, 333}, 17);
    label(*setup_, "Room port", {504, 290}, 15, muted);
    host_port_ = edit(*setup_, {504, 238, 90, 40}, "", 5);
    for (std::size_t index = 0; index < ports_.size(); ++index) {
        ports_[index] = button(*setup_, {604.f + index * 58.f, 238, 54, 40}, "", [this, index] {
            host_port_->setText(std::to_string(port_choices_.at(index)).c_str());
        });
    }
    button(*setup_, {784, 238, 102, 40}, "Randomize", [this] { refresh_ports(); });
    button(*setup_, {74, 144, 358, 46}, "Join", [this] { enter(false); }, true);
    button(*setup_, {504, 144, 382, 46}, "Host", [this] { enter(true); }, true);
    feedback_ = label(*setup_, "", {48, 81}, 17, warning);
    refresh_ports();

    room_ = Node::create();
    addChild(room_);
    room_title_ = label(*room_, "Room", {48, 544}, 42);
    endpoint_ = label(*room_, "", {49, 495}, 17, muted);
    leave_ = button(*room_, {780, 525, 132, 40}, "Leave room", [this] {
        lobby_.leave();
        feedback_->setString("");
        room_feedback_->setString("");
        chat_input_->setText("");
    });
    panel(*room_, {48, 80, 305, 380}, surface);
    panel(*room_, {373, 80, 539, 380}, surface);
    label(*room_, "Players", {70, 422}, 25);
    label(*room_, "Room chat", {396, 422}, 25);
    room_status_ = label(*room_, "", {70, 392}, 15, muted);
    for (std::size_t index = 0; index < players_.size(); ++index) {
        const auto row = 330.f - index * 46.f;
        players_[index] = label(*room_, "", {70, row + 19}, 17);
        kicks_[index] = button(*room_, {249, row, 82, 38}, "Kick", [this, index] {
            if (index < roster_.size()) lobby_.runner()->match().kick(roster_[index]);
        });
    }
    start_ = button(*room_, {70, 105, 261, 44}, "Start game", [this] { lobby_.runner()->match().start(); }, true);
    panel(*room_, {396, 165, 493, 229}, input);
    chat_log_ = ScrollView::create();
    chat_log_->setDirection(ScrollView::Direction::VERTICAL);
    chat_log_->setScrollBarAutoHideEnabled(true);
    chat_log_->setContentSize({475, 210});
    chat_log_->setPosition({405, 175});
    room_->addChild(chat_log_);
    chat_text_ = label(*chat_log_, "", {0, 0}, 16);
    chat_text_->setAnchorPoint({0, 1});
    chat_text_->setDimensions(458, 0);
    chat_input_ = edit(*room_, {396, 105, 394, 44}, "", 512);
    chat_input_->setPlaceHolder("Write a message");
    send_ = button(*room_, {802, 105, 87, 44}, "Send", [this] { send_chat(); }, true);
    room_feedback_ = label(*room_, "", {48, 52}, 17, warning);
    refresh();
}

void LobbyPanel::refresh_ports()
{
    port_choices_ = available_ports();
    for (std::size_t index = 0; index < ports_.size(); ++index) {
        ports_[index]->setVisible(index < port_choices_.size());
        if (index < port_choices_.size()) ports_[index]->setTitleText(std::to_string(port_choices_[index]));
    }
    if (!port_choices_.empty()) host_port_->setText(std::to_string(port_choices_.front()).c_str());
}

void LobbyPanel::enter(bool host)
{
    try {
        lobby_.enter(host, join_ip_->getText(), host ? host_port_->getText() : join_port_->getText());
        feedback_->setString("");
        room_feedback_->setString("");
        chat_input_->setText("");
    } catch (const std::exception& error) {
        feedback_->setString(error.what());
    }
}

void LobbyPanel::send_chat()
{
    if (lobby_.runner()->match().chat(chat_input_->getText())) {
        chat_input_->setText("");
        room_feedback_->setString("");
    } else {
        room_feedback_->setString("Enter a message of up to 512 UTF-8 bytes.");
    }
}

void LobbyPanel::show_chat(const Match& match)
{
    std::string text;
    for (const auto& message : match.messages()) {
        if (!text.empty()) text += '\n';
        text += player_name(message.sender) + ": " + message.text;
    }
    if (text == chat_text_->getString()) return;
    chat_text_->setString(text);
    const auto height = std::max(chat_log_->getContentSize().height, chat_text_->getContentSize().height);
    chat_log_->setInnerContainerSize({475, height});
    chat_text_->setPosition({0, height});
    chat_log_->jumpToBottom();
}

void LobbyPanel::refresh()
{
    const auto* runner = lobby_.runner();
    const auto phase = runner ? runner->match().phase() : RoomPhase::Ended;
    const bool show_setup = phase == RoomPhase::Ended;
    const bool show_room = !show_setup && phase != RoomPhase::Playing;
    const bool waiting = phase == RoomPhase::Waiting;
    setVisible(show_setup || show_room);
    setup_->setVisible(show_setup);
    room_->setVisible(show_room);
    for (auto* field : {join_ip_, join_port_, host_port_}) {
        if (field->isVisible() != show_setup) field->setVisible(show_setup);
    }
    if (chat_input_->isVisible() != waiting) chat_input_->setVisible(waiting);
    if (show_setup) {
        if (runner && feedback_->getString().empty()) feedback_->setString(connection_status(runner->match()));
        return;
    }
    if (!show_room) return;

    feedback_->setString("");
    auto& match = runner->match();
    const bool host = runner->options().host;
    room_title_->setString(waiting ? (host ? "Hosting room" : "Room") : "Connecting");
    endpoint_->setString(lobby_.endpoint() + (waiting ? "     Room " + std::to_string(match.room()) : ""));
    room_status_->setString(waiting ? std::to_string(match.seats()) + " / 4 seats" : "Waiting for the host to respond");
    leave_->setTitleText(waiting ? "Leave room" : "Cancel");
    start_->setVisible(waiting && host);
    send_->setVisible(waiting);
    roster_ = match.players();
    for (std::size_t index = 0; index < players_.size(); ++index) {
        const auto id = index < roster_.size() ? roster_[index] : 0;
        players_[index]->setString(id ? player_name(id) + (id == match.player() ? "  (you)" : "") : "");
        kicks_[index]->setVisible(waiting && host && id > netcode::host_player);
    }
    show_chat(match);
}

}
