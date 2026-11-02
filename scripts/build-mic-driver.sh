#!/usr/bin/env bash
# Builds the Polylocal Microphone HAL plug-in (meeting mode level 4) with libASPL.
#
#   scripts/build-mic-driver.sh                  # ad-hoc signed, for a local test
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-mic-driver.sh
#
# Output: build/mic-driver/PolylocalMicrophone.driver (+ LICENSE.libASPL).
# Install for a local test (admin password, restarts the audio server):
#   sudo cp -R build/mic-driver/PolylocalMicrophone.driver /Library/Audio/Plug-Ins/HAL/ && sudo killall coreaudiod
# Requires: git, cmake (brew install cmake), Xcode command line tools.
set -euo pipefail

TAG="${LIBASPL_TAG:-v3.1.2}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/libASPL-$TAG"
OUT="$ROOT/build/mic-driver"

if [ ! -d "$SRC" ]; then
    git clone --quiet --depth 1 --branch "$TAG" https://github.com/gavv/libASPL "$SRC"
fi

cmake -S "$SRC" -B "$SRC/build-release" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_INSTALL_PREFIX="$SRC/prefix" \
    -DBUILD_TESTING=OFF \
    > "$ROOT/build/libaspl-cmake.log"
cmake --build "$SRC/build-release" --target install -j "$(sysctl -n hw.ncpu)" > "$ROOT/build/libaspl-build.log"

cmake -S "$ROOT/Driver" -B "$ROOT/build/mic-driver-build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DLIBASPL_PREFIX="$SRC/prefix" \
    > "$ROOT/build/mic-driver-cmake.log"
cmake --build "$ROOT/build/mic-driver-build" -j "$(sysctl -n hw.ncpu)" > "$ROOT/build/mic-driver-build.log"

rm -rf "$OUT"
mkdir -p "$OUT"
cp -R "$ROOT/build/mic-driver-build/PolylocalMicrophone.driver" "$OUT/"
cp "$SRC/LICENSE" "$OUT/LICENSE.libASPL"
echo "$TAG" > "$OUT/LIBASPL_VERSION"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$OUT/PolylocalMicrophone.driver"
else
    codesign --force --sign - "$OUT/PolylocalMicrophone.driver"
fi
echo "Built $OUT/PolylocalMicrophone.driver (libASPL $TAG)"
