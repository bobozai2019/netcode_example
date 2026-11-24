#include "layout.hpp"

#include <stdexcept>

namespace yard {
using namespace netcode;

void Layout::validate_yard() const
{
    const std::map<SchemaId, Values> expected{
        {Car, {0.f, 0.f, 0.f, 1.f, 1.f, 0.f, 0.f}},
        {Gate, {0.f, 0.f, 0.f, 1.f, 1.f, false}},
        {Beacon, {0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 1.f, 1.f, 1.f, 0.f}},
        {Barrier, {0.f, 0.f, 0.f, 1.f, 1.f, 0.f}},
        {Load, {0.f, 0.f, 0.f, 1.f, 1.f, 0.f}},
    };
    for (const auto& [id, defaults] : expected) {
        if (!schemas().valid(id, defaults)) throw std::runtime_error("Incompatible yard schema " + std::to_string(id));
    }
}

}
