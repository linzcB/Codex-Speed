#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-$ROOT/dist/release}"
mkdir -p "$DESTINATION"
DESTINATION="$(cd "$DESTINATION" && pwd)"

bash "$ROOT/build.sh" "$DESTINATION"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
ARCHIVE="Codex-Speed-$VERSION.zip"
rm -f "$DESTINATION/$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$DESTINATION/Codex Speed.app" "$DESTINATION/$ARCHIVE"
(
    cd "$DESTINATION"
    shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt
)
printf 'Release package: %s\n' "$DESTINATION/$ARCHIVE"
