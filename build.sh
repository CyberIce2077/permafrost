#!/bin/sh
# Builds "build/Ice Servers.app". Needs only the Xcode Command Line Tools.
set -e
cd "$(dirname "$0")"
APP="build/Ice Servers.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target "$(uname -m)-apple-macos14" Sources/*.swift -o "$APP/Contents/MacOS/IceServers"
cp Resources/* "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"
