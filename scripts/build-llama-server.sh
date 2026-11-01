#!/usr/bin/env bash
# Builds a self-contained llama-server for bundling into Polylocal.app.
#
#   scripts/build-llama-server.sh            # pinned tag
#   LLAMA_TAG=b12000 scripts/build-llama-server.sh
#
# Output: build/llama-server/llama-server (+ LICENSE). Statically linked, Metal shaders embedded,
# no curl/OpenSSL, generic arm64 code (GGML_NATIVE=OFF) so a build made on an M4 also runs on an M1.
# Requires: git, cmake (brew install cmake), Xcode command line tools.
set -euo pipefail

TAG="${LLAMA_TAG:-b11960}"   # the version Polylocal was benchmarked and tested with
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/llama.cpp-$TAG"
OUT="$ROOT/build/llama-server"

if [ ! -d "$SRC" ]; then
    git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$SRC"
fi

cmake -S "$SRC" -B "$SRC/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DLLAMA_CURL=OFF \
    -DLLAMA_OPENSSL=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=ON \
    > "$ROOT/build/llama-cmake.log"
cmake --build "$SRC/build" --target llama-server --config Release -j "$(sysctl -n hw.ncpu)" > "$ROOT/build/llama-build.log"

mkdir -p "$OUT"
cp "$SRC/build/bin/llama-server" "$OUT/llama-server"
cp "$SRC/LICENSE" "$OUT/LICENSE"
echo "$TAG" > "$OUT/VERSION"

# Fail loudly if anything outside the OS slipped in as a dynamic dependency.
if otool -L "$OUT/llama-server" | tail -n +2 | grep -vE '^\s*(/usr/lib/|/System/Library/)'; then
    echo "error: llama-server links non-system libraries (see above)" >&2
    exit 1
fi
echo "Built $OUT/llama-server ($TAG)"
