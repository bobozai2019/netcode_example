if(NOT EXISTS "${NETCODE_GODOT_SDK}/addons/netcode/netcode.gdextension")
    message(FATAL_ERROR "Provide NETCODE_GODOT_SDK, the installed Godot SDK directory")
endif()
set(GODOTCPP_BUILD_PROFILE "${CMAKE_CURRENT_SOURCE_DIR}/build_profile.json")
set(GODOTCPP_DISABLE_EXCEPTIONS OFF)
add_subdirectory("${NETCODE_GODOT_CPP}" godot-cpp EXCLUDE_FROM_ALL)
add_library(netcode_yard_example SHARED bridge.cpp register_types.cpp)
target_include_directories(netcode_yard_example PRIVATE "${NETCODE_GODOT_SDK}/addons/netcode/native")
target_link_libraries(netcode_yard_example PRIVATE godot::cpp yard_match)
set_target_properties(netcode_yard_example PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin/$<CONFIG>/godot/addons/yard/bin")
set(project_source "${PROJECT_SOURCE_DIR}/yard/godot")
set(puzzle_source "${PROJECT_SOURCE_DIR}/puzzle")
set(yard_assets
    yard/yard.tscn yard/yard.gd yard/yard_field.tscn yard/replicator.gd
    yard/lobby/lobby.tscn yard/lobby/lobby.gd
    yard/objects/paint.gd yard/objects/car.tscn yard/objects/lamp.tscn
    yard/objects/gate.tscn yard/objects/beacon.tscn yard/objects/barrier.tscn
    yard/objects/load.tscn yard/objects/profile.tscn
    sync/sync_preview.gd sync/sync_preview.tscn sync/sync_panel.tscn
    sync/switch_panel.gd sync/panel_stats.gd)
set(verification_assets
    sync/scene_controls.tscn sync/scene_controls.gd sync/switch_panel.gd
    components/components.gd components/components.tscn
    physics/island.gd physics/island.tscn physics/island_world.tscn
    physics/forecast.gd physics/forecast.tscn physics/forecast3d.gd physics/forecast3d.tscn
    handoff/handoff.gd handoff/handoff.tscn layout/layout_probe.gd
    plates/plates.gd plates/plates.tscn plates/plate_room.tscn)
set(compat_scripts
    forecast_body.gd physics_island_3d.gd forecast_body_3d.gd layout_exporter.gd
    replicated_object.gd scene_fields.gd scene_replicator.gd scene_room.gd scene_values.gd)

function(copy_godot_asset source destination)
    configure_file("${source}" "${destination}" COPYONLY)
    if(EXISTS "${source}.uid")
        configure_file("${source}.uid" "${destination}.uid" COPYONLY)
    endif()
endfunction()

set(asset_dirs "${CMAKE_CONFIGURATION_TYPES}")
if(NOT asset_dirs)
    set(asset_dirs "${CMAKE_BUILD_TYPE}")
    if(NOT asset_dirs)
        set(asset_dirs ".")
    endif()
endif()
foreach(config IN LISTS asset_dirs)
    set(project_output "${CMAKE_BINARY_DIR}/bin/${config}/godot")
    set(addon_output "${project_output}/addons/netcode")
    file(MAKE_DIRECTORY "${addon_output}/bin")
    foreach(asset IN ITEMS project.godot export_presets.cfg
                           racing/main.gd racing/main.tscn racing/vehicle.gd racing/vehicle.tscn racing/roadster.tscn)
        copy_godot_asset("${project_source}/${asset}" "${project_output}/${asset}")
    endforeach()
    foreach(asset IN LISTS yard_assets)
        copy_godot_asset("${project_source}/${asset}" "${project_output}/${asset}")
    endforeach()
    file(COPY "${NETCODE_GODOT_SDK}/addons/netcode" DESTINATION "${project_output}/addons")
    configure_file(yard.gdextension "${project_output}/addons/yard/yard.gdextension" COPYONLY)
    foreach(script IN LISTS compat_scripts)
        copy_godot_asset("${project_source}/compat/${script}" "${project_output}/compat/${script}")
    endforeach()
    foreach(asset IN LISTS verification_assets)
        copy_godot_asset("${puzzle_source}/godot/${asset}" "${project_output}/verification/${asset}")
    endforeach()
    foreach(cfg IN ITEMS components.cfg island.cfg plates.cfg body.cfg body3d.cfg)
        configure_file("${puzzle_source}/${cfg}" "${project_output}/${cfg}" COPYONLY)
    endforeach()
    configure_file("${PROJECT_SOURCE_DIR}/yard/shared/replicators.cfg" "${project_output}/replicators.cfg" COPYONLY)
endforeach()
