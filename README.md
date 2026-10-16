# Codex Speed

A native macOS menu bar monitor for Codex output speed, token usage, and estimated API-equivalent costs. Reads local logs; no API key is required.

[简体中文使用说明](README.txt)

## Features

- Two menu bar rows: total speed across active chats, and the selected chat's speed.
- Estimated continuous-output speed, first-text latency, and logged first-token latency when available.
- Optional subagent aggregation, active subagent counts, and individual agent details.
- Daily history with input, output, reasoning, cache hit rates, models, and weighted average speed.
- Standard/Fast cost estimates from recorded mode settings, with pricing coverage shown.
- A floating sidebar, CSV export, and English / Simplified Chinese interfaces.

Speed is estimated from log timing rather than measured for each token. Continuous-output mode excludes recorded pre-output waits and tools between output segments; it includes reasoning and tool arguments. Cloud chats require local logs to appear. Cost estimates are not subscription charges or confirmed API bills.

## Build and run

Requires macOS 13 or later and Xcode Command Line Tools with Swift 5.9 or later.

```sh
./build.sh
open "dist/Codex Speed.app"
```

The build contains both Apple Silicon and Intel executables. The app appears in the menu bar. Click its readout for details, or pin the panel as a floating sidebar. The local build uses an ad hoc signature and is not notarized.

## Language

The interface follows your macOS preferred languages by default. Open the **…** menu in the details panel, then **Language**, and choose **Follow system**, **简体中文**, or **English**. Changes take effect immediately and persist across launches. Unsupported system languages fall back to English.

Chat titles, custom agent names, model IDs, and CSV column names retain their original text. Language changes do not change usage totals, history grouping, or pricing calculations.

## Local data

The default source is `~/.codex/sessions`, or the sessions directory under `CODEX_HOME`. You can select another log folder from the details menu. Archived local chats are included in daily history.

The app reads local logs and keeps statistics in memory. It does not upload logs, store extra copies of chat content, or read authentication credentials. Only display preferences and the selected log-folder path are saved locally.

## Tests

```sh
swift test
```

Tests cover usage aggregation, subagents, timing, pricing, history, title lookup, placement, and localization resources.
