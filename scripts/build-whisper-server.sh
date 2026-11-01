#!/usr/bin/env bash
# Builds a self-contained whisper-server (speech recognition for meeting mode) for bundling into Polylocal.app.
#
#   scripts/build-whisper-server.sh            # pinned tag
#   WHISPER_TAG=v1.9.6 scripts/build-whisper-server.sh
#
# Output: build/whisper-server/whisper-server (+ LICENSE). Statically linked, Metal shaders embedded,
# generic arm64 code (GGML_NATIVE=OFF) so a build made on an M4 also runs on an M1.
# Requires: git, cmake (brew install cmake), Xcode command line tools.
set -euo pipefail

TAG="${WHISPER_TAG:-v1.9.5}"   # the version meeting mode was benchmarked with (prototypes/meeting-spikes)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/whisper.cpp-$TAG"
OUT="$ROOT/build/whisper-server"

if [ ! -d "$SRC" ]; then
    git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/whisper.cpp "$SRC"
fi

cmake -S "$SRC" -B "$SRC/build-release" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=ON \
    -DWHISPER_SDL2=OFF \
    -DWHISPER_CURL=OFF \
    > "$ROOT/build/whisper-cmake.log"
cmake --build "$SRC/build-release" --target whisper-server --config Release -j "$(sysctl -n hw.ncpu)" > "$ROOT/build/whisper-build.log"

mkdir -p "$OUT"
cp "$SRC/build-release/bin/whisper-server" "$OUT/whisper-server"
cp "$SRC/LICENSE" "$OUT/LICENSE"
echo "$TAG" > "$OUT/VERSION"

# Fail loudly if anything outside the OS slipped in as a dynamic dependency.
if otool -L "$OUT/whisper-server" | tail -n +2 | grep -vE '^\s*(/usr/lib/|/System/Library/)'; then
    echo "error: whisper-server links non-system libraries (see above)" >&2
    exit 1
fi
echo "Built $OUT/whisper-server ($TAG)"
