# Performance and power use

[Back to the app](../README.md) · [中文常见问题](FAQ.zh-CN.md)

The app uses coalesced file-system notifications plus recovery polling. It keeps one-second monitoring for active chats or visible panels, and slows hidden, idle polling to 30 seconds. Automatic daily-history work pauses while the panel is hidden. Relevant changes to older chats and subagents trigger discovery, even when they are outside the recent-chat list. Wake from system sleep requests a fresh scan.

The implementation caches localization bundles, unchanged database display names, and per-refresh aggregation. Database and WAL changes invalidate title results; generated tests cover renames and database-version changes. Metadata-only discovery avoids timestamp parsing, date parsers are created on demand, and agents are grouped once per scan. Unchanged menu bar strings do not request a repaint. Closing a dashboard detaches its hosting view so it stops observing live updates.

Hourly spending estimates reuse the incremental live reader, cache per-request priced amounts, and retain numeric cost samples for the last 15 minutes. Recent completed/archived families are also scanned for this window; choosing a shorter cost window only changes in-memory aggregation. This may add bounded startup reading for recently active files, but does not trigger a separate full daily-history scan.

## Reproduce the scanning benchmark

```sh
./scripts/benchmark.sh 1000
```

This compiles an optimized local benchmark and generates **1,000 independent chats with three agents each: 4,000 log files**. It uses no account data, performs no network requests, and removes its temporary fixtures when done. It reports full discovery (three scans, including first use), unchanged scans (100), and 1,000 localized string lookups (ten batches). Build files remain under the ignored `build/benchmark/` directory.

## Local comparison — 2026-10-16

Same generated fixture, optimized native builds, with both language resources bundled. Baseline: app source at `adc60d3` (1.1.0); optimized: 1.1.1.

| Operation | 1.1.0 | 1.1.1 |
| --- | ---: | ---: |
| Full discovery, average | 706.1 ms | 161.5 ms |
| Unchanged scan, average | 4.76 ms | 4.50 ms |
| 1,000 localized strings, average | 14.43 ms | 1.31 ms |

A separate 14-second hidden/idle probe after startup recorded 28 update callbacks and automatic history loading in 1.1.0, versus zero callbacks and no history scan in 1.1.1. The latter still schedules a 30-second recovery check. A new generated chat woke idle monitoring in roughly 0.2 seconds; agent totals, title changes, history reopening, and stopping the observer were also checked.

In a separate visible-panel idle probe, 14 seconds used 0.396 seconds of process CPU in 1.1.0 and 0.197 seconds in 1.1.1, with 28 versus 13 update callbacks.

These are local CPU/workload measurements. Hardware power in watts and battery runtime have not been measured. Results depend on disk, cache, hardware, log size, and activity. During initial history loading or active logging, more work is expected.

## Check a change

Run `swift test`, compare the benchmark on the same machine, then check the app with its panel open and closed. Include a resumed old chat and a newly created subagent. Verify that file notifications, fallback polling, manual rescanning, language switching, and reopening history still produce the same totals. Avoid uploading traces that contain real session IDs, chat titles, or private paths.
