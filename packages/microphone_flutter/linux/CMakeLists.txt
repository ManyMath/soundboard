# Builds the shared `microphone` Rust crate via cargokit and bundles the
# resulting libmicrophone.so with the Flutter app.
cmake_minimum_required(VERSION 3.10)

set(PROJECT_NAME "microphone_flutter")
project(${PROJECT_NAME} LANGUAGES CXX)

include("${CMAKE_CURRENT_SOURCE_DIR}/../cargokit/cmake/cargokit.cmake")

# apply_cargokit(<target> <manifest_dir, relative to this file> <lib_name> <force-link symbol>)
# The crate lives at the repo root, shared with the pure-Dart
# `microphone_dart` package.
apply_cargokit(${PROJECT_NAME} ../../../native/microphone microphone "")

set(microphone_flutter_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
