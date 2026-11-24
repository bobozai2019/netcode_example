#include "lobby.hpp"

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#else
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#endif

#include <algorithm>
#include <charconv>
#include <limits>
#include <random>
#include <stdexcept>
#include <tuple>
#include <utility>

namespace yard {
namespace {

std::string local_ipv4()
{
#ifdef _WIN32
    ULONG size = 15000;
    for (int attempt = 0; attempt < 3; ++attempt) {
        std::vector<std::max_align_t> buffer((size + sizeof(std::max_align_t) - 1) / sizeof(std::max_align_t));
        const auto adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
        const auto result = GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_GATEWAYS | GAA_FLAG_SKIP_ANYCAST |
            GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, nullptr, adapters, &size);
        if (result == ERROR_BUFFER_OVERFLOW) continue;
        if (result != NO_ERROR) break;

        std::string best;
        std::tuple<bool, bool, bool, ULONG> priority{true, true, true, std::numeric_limits<ULONG>::max()};
        for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
            if (adapter->OperStatus != IfOperStatusUp || adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
            MIB_IF_ROW2 row{};
            row.InterfaceLuid = adapter->Luid;
            const bool hardware = GetIfEntry2(&row) == NO_ERROR && row.InterfaceAndOperStatusFlags.HardwareInterface;
            for (auto* entry = adapter->FirstUnicastAddress; entry; entry = entry->Next) {
                if (entry->DadState != IpDadStatePreferred || entry->Address.lpSockaddr->sa_family != AF_INET) continue;
                const auto* address = reinterpret_cast<const sockaddr_in*>(entry->Address.lpSockaddr);
                const auto ipv4 = ntohl(address->sin_addr.s_addr);
                const bool link_local = (ipv4 >> 16) == 0xa9fe;
                const std::tuple rank{link_local, !hardware, adapter->FirstGatewayAddress == nullptr, adapter->Ipv4Metric};
                if (rank >= priority) continue;
                char text[INET_ADDRSTRLEN];
                if (!inet_ntop(AF_INET, &address->sin_addr, text, sizeof(text))) continue;
                best = text;
                priority = rank;
            }
        }
        if (!best.empty()) return best;
        break;
    }
#else
    ifaddrs* interfaces = nullptr;
    if (getifaddrs(&interfaces) == 0) {
        const std::unique_ptr<ifaddrs, decltype(&freeifaddrs)> guard(interfaces, &freeifaddrs);
        std::string best;
        std::tuple<bool, std::string, uint32_t> priority{true, "", 0};
        for (auto* entry = interfaces; entry; entry = entry->ifa_next) {
            if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET ||
                !(entry->ifa_flags & IFF_UP) || (entry->ifa_flags & IFF_LOOPBACK)) continue;
            const auto* address = reinterpret_cast<const sockaddr_in*>(entry->ifa_addr);
            const auto ipv4 = ntohl(address->sin_addr.s_addr);
            const std::tuple rank{(ipv4 >> 16) == 0xa9fe, std::string(entry->ifa_name), ipv4};
            if (!best.empty() && rank >= priority) continue;
            char text[INET_ADDRSTRLEN];
            if (!inet_ntop(AF_INET, &address->sin_addr, text, sizeof(text))) continue;
            best = text;
            priority = rank;
        }
        if (!best.empty()) return best;
    }
#endif
    return "127.0.0.1";
}

std::uint16_t port_number(std::string_view text)
{
    unsigned number = 0;
    if (!text.empty()) {
        const auto end = text.data() + text.size();
        const auto result = std::from_chars(text.data(), end, number);
        if (result.ec == std::errc{} && result.ptr == end && number > 0 && number <= 65535) {
            return static_cast<std::uint16_t>(number);
        }
    }
    throw std::invalid_argument("Enter a port from 1 to 65535.");
}

std::string_view trimmed(std::string_view text)
{
    constexpr std::string_view whitespace = " \t\r\n";
    const auto begin = text.find_first_not_of(whitespace);
    if (begin == std::string_view::npos) return {};
    return text.substr(begin, text.find_last_not_of(whitespace) - begin + 1);
}

}

Lobby::Lobby(Options options) : Lobby(options, Layout(options.assets / "replicators.cfg")) {}

Lobby::Lobby(Options options, Layout layout)
    : options_(std::move(options)), layout_(std::move(layout)), local_ip_(local_ipv4())
{
    if (!options_.lobby && !options_.smoke && !options_.binding_smoke) {
        runner_ = std::make_unique<Runner>(options_, layout_);
    }
}

void Lobby::enter(bool host, std::string_view address, std::string_view port)
{
    auto options = options_;
    options.host = host;
    options.steam = false;
    options.address.port = port_number(trimmed(port));
    options.address.address = host ? "0.0.0.0" : std::string(trimmed(address));
    runner_ = std::make_unique<Runner>(std::move(options), layout_);
}

void Lobby::leave()
{
    if (!runner_) return;
    runner_->match().end_room();
    runner_->update(netcode::Clock::now());
    runner_.reset();
}

std::string Lobby::endpoint() const
{
    if (!runner_) return {};
    const auto& options = runner_->options();
    if (options.steam) return "Steam P2P";
    const auto& ip = options.address.address;
    return (ip == "0.0.0.0" ? local_ip_ : ip) + ':' + std::to_string(options.address.port);
}

std::vector<std::uint16_t> available_ports()
{
    std::mt19937 random(std::random_device{}());
    std::uniform_int_distribution<unsigned> candidate(20000, 49151);
    std::vector<std::uint16_t> ports;
    for (int attempt = 0; attempt < 48 && ports.size() < 3; ++attempt) {
        const auto port = static_cast<std::uint16_t>(candidate(random));
        if (std::find(ports.begin(), ports.end(), port) != ports.end()) continue;
        try {
            const auto probe = netcode::listen_direct({"0.0.0.0", port});
            ports.push_back(port);
        } catch (const std::runtime_error&) {
            // Try another port if either socket is unavailable.
        }
    }
    return ports;
}

std::string connection_status(const Match& match)
{
    using netcode::Reject;
    switch (match.rejected()) {
    case Reject::Kicked: return "The host removed you. You can join again.";
    case Reject::Full: return "The room is full.";
    case Reject::Locked: return "The room already started a game.";
    case Reject::BadResume: return "The saved seat is no longer available.";
    case Reject::WrongRoom: return "This is a different room.";
    case Reject::Protocol: return "The host could not accept this game's connection.";
    case Reject::None: break;
    }
    if (match.loss() == netcode::Disconnect::Timeout) return "The host did not respond.";
    if (match.loss() == netcode::Disconnect::IoError) return "Could not reach the host at this address and port.";
    return "Disconnected from the room.";
}

std::string player_name(netcode::PlayerId player)
{
    return player == netcode::host_player ? "Host" : "Player " + std::to_string(player);
}

}
