#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
SWIFT_TOOLCHAIN_DIR="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
TESTING_MACROS="$SWIFT_TOOLCHAIN_DIR/lib/swift/host/plugins/testing/libTestingMacros.dylib"
TESTING_FRAMEWORKS="${SWIFT_TOOLCHAIN_DIR%/usr}/Library/Developer/Frameworks"
swift test --build-system native --scratch-path .build-tests --disable-sandbox --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$TESTING_MACROS" -Xswiftc -F -Xswiftc "$TESTING_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TESTING_FRAMEWORKS" "$@"
