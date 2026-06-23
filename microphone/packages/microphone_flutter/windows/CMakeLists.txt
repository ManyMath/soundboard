# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "microphone_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

include("${CMAKE_CURRENT_SOURCE_DIR}/../cargokit/cmake/cargokit.cmake")

# apply_cargokit(<target> <manifest_dir, relative to this file> <lib_name> <force-link symbol>)
# The crate lives at the repo root, shared with the pure-Dart
# `microphone_dart` package. The last argument is a real exported symbol so
# the linker keeps the cargo library if it is ever force-linked into a target.
apply_cargokit(${PROJECT_NAME} ../../../native/microphone microphone microphone_recorder_new)

set(microphone_flutter_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
