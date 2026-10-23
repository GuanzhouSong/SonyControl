#!/bin/bash
# Builds SonyControl.app into ./build (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SonyControl.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -parse-as-library -o "$APP/Contents/MacOS/SonyControl" Sources/*.swift \
    -framework IOBluetooth -framework SwiftUI -framework ServiceManagement

# Ad-hoc signature so macOS remembers the Bluetooth permission across launches.
codesign --force --sign - "$APP"
echo "Built $APP"
