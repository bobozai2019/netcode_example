#pragma once

#include "state/layout.hpp"

namespace yard {

enum Template : netcode::SchemaId { Car = 1, Gate, Beacon, Barrier, Load, Profile };
using FieldBinding = netcode::FieldBinding;

class Layout : public netcode::ReplicationLayout {
public:
    using ReplicationLayout::ReplicationLayout;
    void validate_yard() const;
};

}
