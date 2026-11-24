add_executable(netcode-puzzle main.cpp)
target_link_libraries(netcode-puzzle PRIVATE Netcode::Direct)

add_executable(netcode-migration migration_main.cpp)
target_link_libraries(netcode-migration PRIVATE Netcode::Direct)
