# HarmonyOS native module: NAPI bridge over the Rust spectral engine.
#
# The engine itself is a Rust static library built by cargo for
# aarch64-unknown-linux-ohos. CMake only compiles the thin C++ NAPI shim and
# links the archive in, so the whole thing ships as one .so inside the HAP.
#
# Build the Rust side first:
#   cd rust
#   cargo build -p spektrafilm-ffi --target aarch64-unknown-linux-ohos --release

cmake_minimum_required(VERSION 3.5.0)
project(spektrafilmoh)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# entry/src/main/cpp -> main -> src -> entry -> project root (four levels up)
set(PROJECT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../..")

# Always link the *release* Rust archive. A debug Rust build of the spectral
# pipeline is roughly 30x slower at runtime and there is no reason to carry it;
# the ArkTS/HAP side still builds debug/release independently.
# Override with -DSPEKTRAFILM_RUST_PROFILE=debug if you need to debug Rust.
if(NOT DEFINED SPEKTRAFILM_RUST_PROFILE)
    set(SPEKTRAFILM_RUST_PROFILE "release")
endif()

set(RUST_LIB
    "${PROJECT_ROOT}/rust/target/aarch64-unknown-linux-ohos/${SPEKTRAFILM_RUST_PROFILE}/libspektrafilm.a")

if(NOT EXISTS "${RUST_LIB}")
    message(FATAL_ERROR
        "Rust engine archive not found at ${RUST_LIB}.\n"
        "Build it first:\n"
        "  cd rust && cargo build -p spektrafilm-ffi "
        "--target aarch64-unknown-linux-ohos --release")
endif()

add_library(spektrafilmoh SHARED napi_init.cpp)

target_include_directories(spektrafilmoh PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# libace_napi.z.so      — ArkTS <-> native bindings
# libhilog_ndk.z.so     — logging
# libtime_service_ndk.so — Rust std's local-time support calls
#                         OH_TimeService_GetTimeZone on the OHOS target.
# The Rust archive needs the usual libc pieces plus libc++ for its unwinder.
target_link_libraries(spektrafilmoh PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libtime_service_ndk.so
    ${RUST_LIB}
    c++_shared
    m
    dl
    pthread
)

# Rust emits its own LTO bitcode in release; keep the linker from choking on
# duplicate/undefined weak unwind symbols from the static archive.
target_link_options(spektrafilmoh PRIVATE
    -Wl,--allow-multiple-definition
    -Wl,--exclude-libs,ALL
)
