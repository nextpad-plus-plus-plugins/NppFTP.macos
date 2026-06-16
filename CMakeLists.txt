cmake_minimum_required(VERSION 3.20)
project(NppFTP VERSION 1.0.0 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OBJCXX_VISIBILITY_PRESET hidden)

# Universal binary (Apple Silicon + Intel). For dev you may pass
# -DCMAKE_OSX_ARCHITECTURES=arm64 to match the dev-only vendored libs.
if(NOT CMAKE_OSX_ARCHITECTURES)
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "" FORCE)
endif()
if(NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "" FORCE)
endif()

set(NPPFTP "${CMAKE_SOURCE_DIR}")

# ── engine sources (validated headless) ─────────────────────────────────────
file(GLOB ENGINE_CORE  "${NPPFTP}/src/engine/*.cpp")
list(FILTER ENGINE_CORE EXCLUDE REGEX "NppFTP\\.cpp$")   # UI glue replaced by ObjC++
file(GLOB ENGINE_UTCP  "${NPPFTP}/src/engine/UTCP/*.cpp")
file(GLOB TINYXML      "${NPPFTP}/deps/tinyxml/*.cpp")
set(SHIM "${NPPFTP}/src/mac/win_compat.cpp")

# ── Cocoa UI (ObjC++) ───────────────────────────────────────────────────────
file(GLOB UI_SOURCES   "${NPPFTP}/src/ui/*.mm")
set(MAC_FS "${NPPFTP}/src/mac/mac_fs.mm")

add_library(NppFTP MODULE
    ${ENGINE_CORE} ${ENGINE_UTCP} ${TINYXML} ${SHIM}
    ${UI_SOURCES} ${MAC_FS})

target_include_directories(NppFTP PRIVATE
    ${NPPFTP}/src/mac
    ${NPPFTP}/src/engine
    ${NPPFTP}/src/engine/UTCP
    ${NPPFTP}/src/ui
    ${NPPFTP}/deps/openssl/include
    ${NPPFTP}/deps/libssh/include
    ${NPPFTP}/deps/tinyxml
    ${NPPFTP}/deps/npp)

target_compile_options(NppFTP PRIVATE -Wno-deprecated-declarations)
target_compile_options(NppFTP PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)

target_link_libraries(NppFTP PRIVATE
    ${NPPFTP}/deps/libssh/lib/libssh.a
    ${NPPFTP}/deps/openssl/lib/libssl.a
    ${NPPFTP}/deps/openssl/lib/libcrypto.a
    z resolv
    "-framework Cocoa" "-framework CoreFoundation" "-framework Security")

set_target_properties(NppFTP PROPERTIES
    PREFIX "" SUFFIX ".dylib" OUTPUT_NAME "NppFTP")
# Stamp version into the dylib Mach-O current_version (Plugins Admin reads it).
target_link_options(NppFTP PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")

set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins/NppFTP")
install(TARGETS NppFTP DESTINATION "${PLUGIN_INSTALL_DIR}")
