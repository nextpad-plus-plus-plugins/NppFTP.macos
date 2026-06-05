#!/bin/bash
# Build + run the profile-lifecycle test against the already-compiled engine
# objects in build-universal/. Validates the refcount ownership (create/load/
# connect/disconnect/delete) + Save/Load round-trips that caused the in-app
# crashes. Run a universal build first: cmake --build build-universal.
set -e
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.."
OBJ=build-universal/CMakeFiles/NppFTP.dir
INC="-Isrc/mac -Isrc/engine -Isrc/engine/UTCP -Ideps/openssl/include -Ideps/libssh/include -Ideps/tinyxml -Ideps/npp"
clang++ -std=c++17 -arch arm64 $INC -Wno-deprecated-declarations -c tests/test_profiles.cpp -o /tmp/test_profiles.o
clang++ -std=c++17 -arch arm64 $INC -Wno-deprecated-declarations -c tests/test_globals.cpp  -o /tmp/test_globals.o
ENG=$(ls $OBJ/src/engine/*.o | grep -v NppFTP.cpp)
UTCP=$(ls $OBJ/src/engine/UTCP/*.o)
TINY=$(ls $OBJ/deps/tinyxml/*.o)
clang++ -arch arm64 /tmp/test_profiles.o /tmp/test_globals.o $ENG $UTCP $TINY \
  $OBJ/src/mac/win_compat.cpp.o $OBJ/src/mac/mac_fs.mm.o \
  deps/libssh/lib/libssh.a deps/openssl/lib/libssl.a deps/openssl/lib/libcrypto.a -lz -lresolv \
  -framework Foundation -framework CoreFoundation -framework Security -framework Cocoa \
  -o /tmp/test_profiles 2>/dev/null
/tmp/test_profiles
