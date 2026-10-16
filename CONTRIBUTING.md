# Contributing

Thanks for helping improve Codex Speed. Issues and pull requests can be written in English or Chinese.

## Before changing code

For a behavior change, describe the observed problem and intended result. For a usage or speed discrepancy, specify the metric, date, time zone, and whether subagents are included. Use a small generated log fixture rather than a real conversation log.

## Build and validate

On macOS with Xcode Command Line Tools and Swift 5.9 or later:

```sh
swift test
./build.sh
```

The build script creates a universal Apple Silicon / Intel app. Use `./scripts/package-release.sh` to also create a ZIP and a matching `SHA256SUMS.txt` under `dist/release/`.

## Where things live

| Path | Purpose |
| --- | --- |
| `Sources/CodexSpeed` | Menu bar, floating panel, live view, and daily history UI |
| `Sources/SpeedCore` | Log parsing, timing, aggregation, titles, pricing, and localization |
| `Sources/SpeedCore/Resources` | English and Simplified Chinese strings |
| `Tests/SpeedCoreTests` | Generated log fixtures and behavior tests |
| `docs` | User-facing definitions, troubleshooting, and demo screenshots |

## Changes worth checking

- Usage changes must avoid double-counting copied history, cumulative totals, duplicate records, and subagents.
- Timing changes should explain which waits and output segments are included. Add a focused fixture for a changed edge case.
- Pricing changes need official source links and the appropriate catalog date. Preserve unknown modes and incomplete coverage instead of guessing a price.
- UI changes should work in English and 简体中文, including the fixed-width panel. Update both string catalogs together and keep chat titles / model identifiers unchanged.
- Screenshots must use demo data. Do not commit local logs, account usage, credentials, absolute home-directory paths, or build caches.

## Pull requests

Keep a change focused. Explain the resulting behavior and how you validated it. For visible UI changes, include a screenshot with generated data. The CI workflow runs tests and builds the universal app.
