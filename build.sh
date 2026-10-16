#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${CODEX_SPEED_BUILD_DIR:-$ROOT/build}"
DESTINATION="${1:-$ROOT/dist}"
APP="$DESTINATION/Codex Speed.app"
mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources"
FILES=("$ROOT/Sources/SpeedCore/UsageFilter.swift" "$ROOT/Sources/SpeedCore/SessionDirectoryObserver.swift" "$ROOT/Sources/SpeedCore/RefreshPolicy.swift" "$ROOT/Sources/SpeedCore/Localization.swift" "$ROOT/Sources/SpeedCore/LogReader.swift" "$ROOT/Sources/SpeedCore/ToolTiming.swift" "$ROOT/Sources/SpeedCore/OutputTiming.swift" "$ROOT/Sources/SpeedCore/SessionFamily.swift" "$ROOT/Sources/SpeedCore/DailyStatistics.swift" "$ROOT/Sources/SpeedCore/ApiPricing.swift" "$ROOT/Sources/SpeedCore/SessionTitles.swift" "$ROOT/Sources/SpeedCore/ScreenPlacement.swift" "$ROOT/Sources/CodexSpeed/Monitor.swift" "$ROOT/Sources/CodexSpeed/DashboardMenu.swift" "$ROOT/Sources/CodexSpeed/Dashboard.swift" "$ROOT/Sources/CodexSpeed/DailyHistoryView.swift" "$ROOT/Sources/CodexSpeed/Main.swift")
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for ARCH in arm64 x86_64; do
    xcrun swiftc -O -swift-version 5 -parse-as-library -module-name CodexSpeed \
        -target "$ARCH-apple-macosx13.0" -sdk "$SDK" \
        -framework AppKit -framework SwiftUI \
        "${FILES[@]}" -o "$BUILD_DIR/CodexSpeed-$ARCH"
done
xcrun lipo -create "$BUILD_DIR/CodexSpeed-arm64" "$BUILD_DIR/CodexSpeed-x86_64" -output "$APP/Contents/MacOS/CodexSpeed"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/Sources/SpeedCore/Resources/en.lproj" "$ROOT/Sources/SpeedCore/Resources/zh-Hans.lproj" "$APP/Contents/Resources/"
if [ -f "$ROOT/LICENSE" ]; then
    cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
else
    rm -f "$APP/Contents/Resources/LICENSE"
fi
codesign --force --sign - --options runtime "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
