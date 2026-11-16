# Copyright Francesco Di Blasi 2026 - All Rights Reserved

cmake_minimum_required(VERSION 3.20)
project(crimson-weapon-animation-tweaker LANGUAGES CXX)

if(NOT WIN32 OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "The Tweaker addon targets Windows x86-64.")
endif()

set(GODOT_CPP_DIR "" CACHE PATH "Path to a Godot 4.7 godot-cpp source checkout")
if(NOT EXISTS "${GODOT_CPP_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "Set GODOT_CPP_DIR to a godot-cpp source checkout with the Godot 4.7 API.")
endif()
set(GODOTCPP_API_VERSION "4.7")
set(GODOTCPP_PRECISION "single")
set(GODOTCPP_BUILD_PROFILE "${CMAKE_CURRENT_SOURCE_DIR}/build_profile.json")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${GODOTCPP_BUILD_PROFILE}")
set(GODOTCPP_TARGET "template_debug" CACHE STRING "Godot binding build target")
set_property(CACHE GODOTCPP_TARGET PROPERTY STRINGS "template_debug" "template_release")
if(NOT GODOTCPP_TARGET MATCHES "^(template_debug|template_release)$")
    message(FATAL_ERROR "Choose template_debug or template_release.")
endif()

add_subdirectory("${GODOT_CPP_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/godot-cpp")
file(GLOB animation_sources CONFIGURE_DEPENDS
    "src/modules/weapon_animation/*.cpp"
    "src/modules/weapon_animation/editor/*.cpp"
    "src/editor/ui/*.cpp"
)
add_library(weapon_animation_tweaker SHARED src/register_types.cpp ${animation_sources})
target_compile_features(weapon_animation_tweaker PRIVATE cxx_std_17)
target_include_directories(weapon_animation_tweaker PRIVATE src)
target_link_libraries(weapon_animation_tweaker PRIVATE godot::cpp)
target_compile_options(weapon_animation_tweaker PRIVATE $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
set_target_properties(weapon_animation_tweaker PROPERTIES
    OUTPUT_NAME "weapon_animation_tweaker.windows.${GODOTCPP_TARGET}.x86_64"
    PREFIX ""
)

if(GODOTCPP_TARGET STREQUAL "template_debug")
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    file(GLOB class_docs CONFIGURE_DEPENDS "src/modules/weapon_animation/doc_classes/*.xml")
    set(doc_source "${CMAKE_CURRENT_BINARY_DIR}/doc_data.gen.cpp")
    add_custom_command(OUTPUT "${doc_source}"
        COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/generate_docs.py"
            "${GODOT_CPP_DIR}/doc_source_generator.py" "${doc_source}" ${class_docs}
        DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/generate_docs.py" "${GODOT_CPP_DIR}/doc_source_generator.py" ${class_docs}
        VERBATIM
    )
    target_sources(weapon_animation_tweaker PRIVATE "${doc_source}")
endif()

install(TARGETS weapon_animation_tweaker RUNTIME DESTINATION bin)
install(FILES addon/weapon_animation_tweaker.gdextension DESTINATION .)
install(FILES "${GODOT_CPP_DIR}/LICENSE.md" DESTINATION licenses RENAME godot-cpp-MIT.md)
