#!/bin/sh
# Builds "build/Ice Servers.app" with its widget extension. Needs Xcode installed (never opened):
# macOS only shows the widget's Edit Widget options with metadata from Xcode's App Intents tool.
# ./build.sh --install also copies it to /Applications and opens it (widgets need a stable home).
set -e
cd "$(dirname "$0")"
APP="build/Ice Servers.app"
WIDGET="$APP/Contents/PlugIns/IceWidgets.appex"
TARGET="$(uname -m)-apple-macos14"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
METADATA=$(xcrun --find appintentsmetadataprocessor 2>/dev/null) || { echo "Install Xcode from the App Store first." >&2; exit 1; }
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WIDGET/Contents/MacOS"
swiftc -O -target "$TARGET" Sources/*.swift Shared/*.swift -o "$APP/Contents/MacOS/IceServers"
# The widget, plus the constant values the App Intents tool reads its Edit Widget options from.
mkdir -p build/intents
echo '["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding","AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider","_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable","IntentValueQuery","Resolver"]' > build/intents/protocols.json
xcrun swiftc -O -wmo -target "$TARGET" -module-name IceWidgets -parse-as-library -application-extension \
  -emit-const-values-path build/intents/IceWidgets.swiftconstvalues -Xfrontend -const-gather-protocols-file -Xfrontend build/intents/protocols.json \
  -Xlinker -e -Xlinker _NSExtensionMain Widget/*.swift Shared/*.swift -o "$WIDGET/Contents/MacOS/IceWidgets"
ls Widget/*.swift Shared/*.swift > build/intents/sources
echo build/intents/IceWidgets.swiftconstvalues > build/intents/constvalues
mkdir -p "$WIDGET/Contents/Resources"
"$METADATA" --output "$WIDGET/Contents/Resources" --toolchain-dir "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain" \
  --module-name IceWidgets --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "$(/usr/libexec/PlistBuddy -c 'Print ProductBuildVersion' "$DEVELOPER_DIR/../version.plist")" \
  --platform-family macOS --deployment-target 14.0 --target-triple "$TARGET" --binary-file "$WIDGET/Contents/MacOS/IceWidgets" \
  --source-file-list build/intents/sources --swift-const-vals-list build/intents/constvalues \
  --deployment-aware-processing --no-app-shortcuts-localization --force
rm -rf build/intents
cp Resources/* "$APP/Contents/Resources/"
swift tools/icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns" && rm -rf build/AppIcon.iconset
cp Info.plist "$APP/Contents/"
cp Widget/Info.plist "$WIDGET/Contents/"
codesign --force --sign - --entitlements Widget/Widget.entitlements "$WIDGET"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "$1" = "--install" ]; then
  pkill -x IceServers || true
  rm -rf "/Applications/Ice Servers.app"
  cp -R "$APP" /Applications/
  killall IceWidgets 2>/dev/null || true  # the old widget process would keep running the old code
  # Re-register so macOS drops cached widget kinds that no longer exist.
  pluginkit -r "/Applications/Ice Servers.app/Contents/PlugIns/IceWidgets.appex" 2>/dev/null
  pluginkit -a "/Applications/Ice Servers.app/Contents/PlugIns/IceWidgets.appex"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
  rm -rf build
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "/Applications/Ice Servers.app"
  open "/Applications/Ice Servers.app"
  echo "Installed /Applications/Ice Servers.app"
fi
