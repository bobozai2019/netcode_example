add_library(netcode_yard_unity SHARED bridge.cpp)
target_link_libraries(netcode_yard_unity PRIVATE yard_match)
set_target_properties(netcode_yard_unity PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
