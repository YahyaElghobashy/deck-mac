#!/bin/zsh
# Deck: menu-bar helper + WidgetKit extension, built with swiftc + codesign (no Xcode).
#   ./build.sh            → build/Deck.app
#   ./build.sh --install  → copy to /Applications, register widget, launch (background)
set -euo pipefail
cd "$(dirname "$0")"
if [[ -z "${DEVELOPER_DIR:-}" && -d "$HOME/Developer/CLT27/Library/Developer/CommandLineTools" ]]; then
  export DEVELOPER_DIR="$HOME/Developer/CLT27/Library/Developer/CommandLineTools"
fi
ROOT="$PWD"; BUILD="$ROOT/build"; APP="$BUILD/Deck.app"; APPEX="$APP/Contents/PlugIns/DeckWidget.appex"; TMP="$BUILD/tmp"
APP_ID="com.yahya.deck"; WIDGET_ID="com.yahya.deck.widget"; MIN_OS="14.0"; VERSION="1.1.0"; BUILD_NUM="$(date +%Y%m%d%H%M)"
ARCH="$(uname -m)"; TARGET="${ARCH}-apple-macos${MIN_OS}"; INSTALL_DIR="${INSTALL_DIR:-/Applications}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"; SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"; SWIFTC="$(xcrun -f swiftc)"
echo "▸ swiftc : $("$SWIFTC" --version 2>&1 | head -1)"; echo "▸ target : $TARGET (SDK $SDK_VER)"
rm -rf "$BUILD"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources" "$TMP"
SHARED=( "$ROOT"/Sources/Shared/*.swift )
APP_SHARED=( ${SHARED:#*Intents.swift} )
COMMON=( -O -swift-version 5 -parse-as-library -target "$TARGET" -sdk "$SDK" -suppress-warnings )

# Murmur, the voice core (Packages/Murmur), compiled first as a static library Deck links. It
# runs whisper.cpp in process from vendor/whisper (static, Metal embedded; vendor/fetch-whisper.sh).
WHISPER="$ROOT/vendor/whisper"
[[ -f "$WHISPER/lib/libwhisper.a" ]] || "$ROOT/vendor/fetch-whisper.sh"
CWHISPER=( -I "$ROOT/Packages/Murmur/Sources/CWhisper" )
WHISPER_LINK=( -L "$WHISPER/lib" -lwhisper -lggml -lggml-base -lggml-cpu -lggml-metal -lggml-blas -lc++
  -framework Metal -framework MetalKit -framework Accelerate )
MODULES="$TMP/modules"; mkdir -p "$MODULES"
echo "▸ compiling Murmur…"
"$SWIFTC" "${COMMON[@]}" -whole-module-optimization -module-name Murmur "${CWHISPER[@]}" \
  -emit-module -emit-module-path "$MODULES/Murmur.swiftmodule" \
  -emit-library -static -o "$MODULES/libMurmur.a" "$ROOT"/Packages/Murmur/Sources/Murmur/*.swift

echo "▸ compiling app…"
"$SWIFTC" "${COMMON[@]}" -module-name Deck -I "$MODULES" "${CWHISPER[@]}" -L "$MODULES" -lMurmur "${WHISPER_LINK[@]}" \
  "${APP_SHARED[@]}" "$ROOT"/Sources/App/*.swift "$ROOT"/Sources/App/Dictation/*.swift \
  -framework SwiftUI -framework AppKit -framework WidgetKit -framework AppIntents -framework Speech -framework AVFoundation \
  -framework Carbon -framework Combine -o "$APP/Contents/MacOS/Deck"

echo "▸ compiling widget extension…"   # entry must be _NSExtensionMain (Xcode does the same); Swift main → WidgetBundle.main() traps in ExtensionKit bootstrap
"$SWIFTC" "${COMMON[@]}" -D WIDGET_EXTENSION -application-extension -module-name DeckWidget "${SHARED[@]}" "$ROOT"/Sources/Widget/*.swift \
  -framework SwiftUI -framework WidgetKit -framework AppIntents -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$APPEX/Contents/MacOS/DeckWidget"

META="$APPEX/Contents/Resources/Metadata.appintents"; mkdir -p "$META"
# The exact mangled type name, as the compiler emitted it (word substitutions included): the
# AppIntents runtime matches it byte for byte against the metadata below.
MANGLED="$(nm "$APPEX/Contents/MacOS/DeckWidget" | grep -o '\$s[A-Za-z0-9_]*IntentVMa$' | head -1 | sed 's/^\$s//; s/Ma$//')"
[[ -n "$MANGLED" ]] || { echo "✗ could not find the intent type in the widget binary" >&2; exit 1; }
python3 - "$META" "$MANGLED" <<'PY'
import json, sys, os
meta = sys.argv[1]
mangled = sys.argv[2]
def param(name, title):
    return {"capabilities": 0, "dynamicOptionsSupport": 0, "inputConnectionBehavior": 0, "isInput": False, "isOptional": False,
            "name": name, "resolvableInputTypes": [{"kindValue": 0, "valueType": {"primitive": {"wrapper": {"typeIdentifier": 12}}}}, {"kindValue": 0, "valueType": {"primitive": {"wrapper": {"typeIdentifier": 0}}}}], "title": {"alternatives": [], "key": title}, "typeSpecificMetadata": [],
            "valueType": {"primitive": {"wrapper": {"typeIdentifier": 12}}}}
action = {"assistantDefinedSchemas": [], "assistantDefinedSchemaTraits": [], "authenticationPolicy": 0,
  "availabilityAnnotations": {"LNPlatformNameWildcard": {"introducedVersion": "*"}},
  "descriptionMetadata": {"descriptionText": {"alternatives": [], "key": "Runs a Deck widget button."}, "searchKeywords": []},
  "effectiveBundleIdentifiers": [], "fullyQualifiedTypeName": "DeckWidget.DeckActionIntent", "identifier": "DeckActionIntent",
  "isAuthPolExplicit": False, "isDiscoverable": False,
  "mangledTypeName": mangled, "mangledTypeNameByBundleIdentifier": {}, "mangledTypeNameByBundleIdentifierV2": {},
  "mangledTypeNameV2": mangled, "openAppWhenRun": False, "outputFlags": 0,
  "parameters": [param("kind", "Kind"), param("target", "Target")],
  "presentationStyle": 0, "requiredCapabilities": [], "supportedModes": 1,
  "systemProtocolMetadata": [], "systemProtocolMetadataV2": [], "systemProtocols": [],
  "title": {"alternatives": [], "key": "Deck Action"}, "typeSpecificMetadata": [],
  "visibilityMetadata": {"assistantOnly": False, "isDiscoverable": False}}
doc = {"actions": {"DeckActionIntent": action}, "assistantEntities": [], "assistantIntentNegativePhrases": [], "assistantIntents": [],
  "autoShortcuts": [], "entities": {}, "enums": [], "generator": {"name": "xcode-tools", "version": "27A200c"},
  "negativePhrases": [], "queries": {}, "shortcutTileColor": 14, "version": 1}
json.dump(doc, open(os.path.join(meta, "extract.actionsdata"), "w"), indent=2)
json.dump({"toolsVersion": "27A200c", "version": "3.0"}, open(os.path.join(meta, "version.json"), "w"), indent=2)
PY

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Deck</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>$APP_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Deck</string>
	<key>CFBundleDisplayName</key><string>Deck</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUM</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
	<key>DTPlatformName</key><string>macosx</string>
	<key>DTPlatformVersion</key><string>$SDK_VER</string>
	<key>DTSDKName</key><string>macosx$SDK_VER</string>
	<key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
	<key>LSUIElement</key><true/>
	<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSMicrophoneUsageDescription</key><string>Deck listens only while “Ask Alexa” is active, then stops on its own.</string>
	<key>NSSpeechRecognitionUsageDescription</key><string>Turns what you said into the text sent to your Echo (on-device when available).</string>
	<key>CFBundleURLTypes</key>
	<array><dict><key>CFBundleURLName</key><string>$APP_ID</string><key>CFBundleURLSchemes</key><array><string>deck</string></array></dict></array>
</dict>
</plist>
PLIST
cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>DeckWidget</string>
	<key>CFBundleIdentifier</key><string>$WIDGET_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>DeckWidget</string>
	<key>CFBundleDisplayName</key><string>Deck</string>
	<key>CFBundlePackageType</key><string>XPC!</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUM</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
	<key>DTPlatformName</key><string>macosx</string>
	<key>DTPlatformVersion</key><string>$SDK_VER</string>
	<key>DTSDKName</key><string>macosx$SDK_VER</string>
	<key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
	<key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict>
</plist>
PLIST

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "▸ rendering icon…"; swift "$ROOT/Resources/MakeIcon.swift" "$TMP/icon1024.png"
  ICONSET="$TMP/AppIcon.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do sips -z $s $s "$TMP/icon1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null; d=$((s*2)); sips -z $d $d "$TMP/icon1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null; done
  iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
fi
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT"/Resources/Art/*.png "$APP/Contents/Resources/"
echo "APPL????" > "$APP/Contents/PkgInfo"

echo "▸ bundling bridge…"
mkdir -p "$APP/Contents/Resources/bridge" "$APP/Contents/Resources/bin"
cp "$ROOT/bridge/bridge.js" "$ROOT/bridge/package.json" "$APP/Contents/Resources/bridge/"
ditto "$ROOT/bridge/node_modules" "$APP/Contents/Resources/bridge/node_modules"
if [[ -x "$ROOT/vendor/node" ]]; then mkdir -p "$APP/Contents/Resources/bridge/bin"; cp "$ROOT/vendor/node" "$APP/Contents/Resources/bridge/bin/node"; echo "  + bundled node"; fi
if [[ -x "$ROOT/vendor/whisper-cli" ]]; then cp "$ROOT/vendor/whisper-cli" "$APP/Contents/Resources/bin/whisper-cli"; echo "  + bundled whisper-cli"; fi

# Prefer the Yaya Suite identity (own keychain, known password → never a keychain prompt); the older
# "Deck Local Signing" sits in the login keychain and codesign can block on a SecurityAgent dialog.
IDENTITY="-"
SUITE_KC="$HOME/Library/Keychains/yayasuite-signing.keychain-db"
if [[ -f "$SUITE_KC" ]] && security unlock-keychain -p yayasuite-signing "$SUITE_KC" 2>/dev/null \
   && security find-certificate -c "Yaya Suite Signing" "$SUITE_KC" >/dev/null 2>&1; then
  IDENTITY="Yaya Suite Signing"
elif security find-certificate -c "Deck Local Signing" >/dev/null 2>&1; then
  IDENTITY="Deck Local Signing"
fi
echo "▸ signing as $IDENTITY…"
for bin in "$APP/Contents/Resources/bridge/bin/node" "$APP/Contents/Resources/bin/whisper-cli"; do
  [[ -f "$bin" ]] && codesign --force --sign "$IDENTITY" "$bin"
done
codesign --force --sign "$IDENTITY" --identifier "$WIDGET_ID" --entitlements "$ROOT/Resources/Widget.entitlements" "$APPEX"
codesign --force --sign "$IDENTITY" --identifier "$APP_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "✓ built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$INSTALL_DIR/Deck.app"
  osascript -e 'tell application id "com.yahya.deck" to quit' >/dev/null 2>&1 || true
  pkill -f "DeckWidget.appex/Contents/MacOS/DeckWidget" >/dev/null 2>&1 || true
  pluginkit -r "$APPEX" >/dev/null 2>&1 || true
  sleep 1; rm -rf "$DEST"; ditto "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  pluginkit -a "$DEST/Contents/PlugIns/DeckWidget.appex" >/dev/null 2>&1 || true
  open -g "$DEST"
  echo "✓ installed + launched (menu bar). Widget: right-click desktop → Edit Widgets → “Deck”."
fi
