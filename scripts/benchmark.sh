#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/build/benchmark"
APP="$OUTPUT/Benchmark.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OUTPUT/module-cache"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.codexspeed.benchmark</string>
<key>CFBundleExecutable</key><string>Benchmark</string>
</dict></plist>
PLIST
cp -R "$ROOT/Sources/SpeedCore/Resources/en.lproj" "$ROOT/Sources/SpeedCore/Resources/zh-Hans.lproj" "$APP/Contents/Resources/"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
env CLANG_MODULE_CACHE_PATH="$OUTPUT/module-cache" xcrun swiftc -O -parse-as-library -swift-version 5 \
    -sdk "$SDK" "$ROOT"/Sources/SpeedCore/*.swift "$ROOT/scripts/benchmark.swift" \
    -o "$APP/Contents/MacOS/Benchmark"
"$APP/Contents/MacOS/Benchmark" "${1:-1000}"
