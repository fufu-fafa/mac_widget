#!/bin/bash
# Builds build/DeskStats.app (desktop widgets + Notification Center widget extension).
# Usage: ./build.sh [run|install]
#   run      build, then launch from build/
#   install  build, copy to /Applications and launch (so macOS lists the widgets)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/DeskStats.app
APPEX="$APP/Contents/PlugIns/DeskStatsWidget.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APPEX/Contents/MacOS"

# Widget extension (sandboxed, as WidgetKit requires).
cp Widget/Info.plist "$APPEX/Contents/Info.plist"
swiftc -O -swift-version 5 -parse-as-library -application-extension \
    -target "$(uname -m)-apple-macos14.0" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    Widget/*.swift Shared/*.swift -o "$APPEX/Contents/MacOS/DeskStatsWidget"
codesign --force --sign - --entitlements Widget/Widget.entitlements "$APPEX"

# Host app.
cp Info.plist "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 Sources/*.swift Shared/*.swift -o "$APP/Contents/MacOS/DeskStats"
codesign --force --sign - "$APP"
echo "Built $APP"

case "${1:-}" in
run)
    pkill -x DeskStats 2>/dev/null || true
    open "$APP"
    ;;
install)
    pkill -x DeskStats 2>/dev/null || true
    rm -rf /Applications/DeskStats.app
    cp -R "$APP" /Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R /Applications/DeskStats.app
    open /Applications/DeskStats.app
    echo "Installed /Applications/DeskStats.app"
    ;;
esac
