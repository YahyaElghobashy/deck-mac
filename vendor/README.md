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

## `vendor/whisper` and `vendor/whisper-cli` — static whisper.cpp with Metal embedded

```bash
./fetch-whisper.sh       # downloads a pinned release, checks its SHA-256, builds both
```

Murmur runs whisper.cpp **in process**: `vendor/whisper/{include,lib}` holds the header and the
static libraries (`libwhisper.a`, `libggml*.a`) that `build.sh` links into Deck, so the model stays
loaded between dictations. `vendor/whisper-cli` is the same release as a single executable, kept
as the fallback when the in-process engine cannot start. `build.sh` runs `fetch-whisper.sh` itself
when the libraries are missing. The pinned version and checksum are at the top of the script.

`BUILD_SHARED_LIBS=OFF` plus `GGML_METAL_EMBED_LIBRARY=ON` is the whole trick: it produces one
~3 MB executable with the Metal shaders baked in and no `libwhisper`/`libggml`/`libomp` to chase
at runtime. Check your work with `otool -L vendor/whisper-cli` — nothing outside `/usr/lib` and
`/System` should be listed.

The speech **model** is not vendored. It is downloaded once to
`~/.local/share/whisper-models/` (see the README).
