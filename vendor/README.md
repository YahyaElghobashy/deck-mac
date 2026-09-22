# vendor/ — the two binaries that make Deck self-contained

A release build of Deck carries its own Node runtime and its own whisper.cpp, so an installed
copy needs neither Homebrew nor nvm nor a terminal. Neither binary is committed here (they are
large and easy to reproduce); `build.sh` picks them up automatically when they exist, and falls
back to whatever Node and `whisper-cli` are on your PATH when they do not.

## `vendor/node` — Node 20, arm64

```bash
./fetch-node.sh          # downloads the official build, extracts bin/node, verifies it runs
```

The official Node binary has no third-party dylib dependencies, so copying that one file into the
app bundle is enough.

## `vendor/whisper-cli` — static whisper.cpp with Metal embedded

```bash
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build -DBUILD_SHARED_LIBS=OFF -DGGML_METAL_EMBED_LIBRARY=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build build --config Release -j
cp build/bin/whisper-cli ../vendor/whisper-cli
```

`BUILD_SHARED_LIBS=OFF` plus `GGML_METAL_EMBED_LIBRARY=ON` is the whole trick: it produces one
~3 MB executable with the Metal shaders baked in and no `libwhisper`/`libggml`/`libomp` to chase
at runtime. Check your work with `otool -L vendor/whisper-cli` — nothing outside `/usr/lib` and
`/System` should be listed.

The speech **model** is not vendored. It is downloaded once to
`~/.local/share/whisper-models/` (see the README).
