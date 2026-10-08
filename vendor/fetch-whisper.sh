#!/bin/zsh
# Builds whisper.cpp from a pinned release: static libraries for Murmur's in-process engine
# (vendor/whisper/{include,lib}) and the static whisper-cli fallback (vendor/whisper-cli).
# Metal shaders are embedded, so nothing needs Xcode's Metal compiler and nothing is loaded
# from Homebrew at runtime.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="1.9.5"
SHA256="ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720"
if [[ -z "${DEVELOPER_DIR:-}" && -d "$HOME/Developer/CLT27/Library/Developer/CommandLineTools" ]]; then
  export DEVELOPER_DIR="$HOME/Developer/CLT27/Library/Developer/CommandLineTools"
fi

WORK="$PWD/.whisper-build"; SRC="$WORK/whisper.cpp-$VERSION"; OUT="$PWD/whisper"
mkdir -p "$WORK"
TARBALL="$WORK/whisper-$VERSION.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
  echo "▸ downloading whisper.cpp v$VERSION"
  curl -fsSL "https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v$VERSION" -o "$TARBALL"
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null || { echo "✗ checksum mismatch for $TARBALL" >&2; rm -f "$TARBALL"; exit 1; }
rm -rf "$SRC"; tar -xzf "$TARBALL" -C "$WORK"

echo "▸ building (static, Metal embedded)"
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF >/dev/null
cmake --build "$SRC/build" --config Release -j 8 --target whisper whisper-cli >/dev/null

rm -rf "$OUT"; mkdir -p "$OUT/include" "$OUT/lib"
cp "$SRC/include/whisper.h" "$SRC"/ggml/include/*.h "$OUT/include/"
find "$SRC/build" -name "*.a" -exec cp {} "$OUT/lib/" \;
cp "$SRC/build/bin/whisper-cli" "$PWD/whisper-cli"
echo "$VERSION" > "$OUT/VERSION"

echo "✓ whisper.cpp $VERSION → vendor/whisper ($(ls "$OUT/lib" | tr '\n' ' '))"
otool -L "$PWD/whisper-cli" | tail -n +2 | grep -v -E "^\s+/(usr/lib|System)/" && { echo "✗ whisper-cli links outside /usr/lib and /System" >&2; exit 1; } || true
