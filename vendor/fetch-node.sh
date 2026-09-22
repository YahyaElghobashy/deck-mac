#!/bin/zsh
# Downloads the official Node 20 arm64 build and keeps just the binary.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-v20.19.0}"
TARBALL="node-$VERSION-darwin-arm64.tar.gz"
echo "▸ fetching $TARBALL…"
curl -fL -o "$TARBALL" "https://nodejs.org/dist/$VERSION/$TARBALL"
echo "▸ verifying checksum…"
curl -fsSL "https://nodejs.org/dist/$VERSION/SHASUMS256.txt" | grep " $TARBALL\$" | shasum -a 256 -c -
tar -xzf "$TARBALL" "node-$VERSION-darwin-arm64/bin/node"
mv "node-$VERSION-darwin-arm64/bin/node" node
rm -rf "node-$VERSION-darwin-arm64" "$TARBALL"
chmod +x node
echo "✓ vendor/node is $(./node --version)"
