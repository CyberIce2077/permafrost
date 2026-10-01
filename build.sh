#!/bin/sh
# Builds "build/Ice Servers.app" with its widget extension. Needs only the Xcode Command Line Tools.
# ./build.sh --install also copies it to /Applications and opens it (widgets need a stable home).
set -e
cd "$(dirname "$0")"
APP="build/Ice Servers.app"
WIDGET="$APP/Contents/PlugIns/IceWidgets.appex"
TARGET="$(uname -m)-apple-macos14"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WIDGET/Contents/MacOS"
swiftc -O -target "$TARGET" Sources/*.swift Shared/*.swift -o "$APP/Contents/MacOS/IceServers"
swiftc -O -target "$TARGET" -parse-as-library -application-extension -Xlinker -e -Xlinker _NSExtensionMain Widget/*.swift Shared/*.swift -o "$WIDGET/Contents/MacOS/IceWidgets"
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
