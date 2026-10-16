# Changelog

## 1.1.4 — 2026-10-16

- Show language choices directly in the More menu, avoiding the hover transition into a disappearing submenu.
- Keep the selected language checked, with immediate updates and persistence.
- Keep native menu tracking independent of live statistics so refreshes cannot rebuild an open menu.
- Treat menu clicks and Escape as menu interactions, and preserve a visible panel when the app is reopened.

## 1.1.3 — 2026-10-16

- Apply the auto review switch to both live speed rows, active agent counts, current-round and session totals, daily history, and CSV exports.
- Filter mixed-model turns per request, including their output samples; retain original agent details with exclusion labels.
- Keep model usage beyond the live view's recent-turn limit and read missing prefixes in bounded background batches when needed.

## 1.1.2 — 2026-10-16

- Add a persistent daily-history switch to include or exclude Codex auto review, off by default.
- Apply exclusions per recorded model to input, output, reasoning, cache statistics, weighted speed, and cost coverage; show excluded usage separately.
- Keep review-only dates selectable and allow restoring excluded data without modifying logs.
- Preserve live speed and session totals independently of the daily-history filter.

## 1.1.1 — 2026-10-16

- Wake from relevant file-system changes and reduce hidden, idle polling from one second to 30 seconds, with polling fallback.
- Pause automatic daily-history scans while the panel is hidden and release closed dashboard views.
- Cache localization bundles, unchanged database titles, and per-refresh statistics; avoid repainting unchanged menu bar text.
- Skip timestamp parsing for metadata-only discovery, create date parsers on demand, and group agent files once per scan.
- Preserve forced refreshes received during an in-flight scan and refresh after system wake.
- Add a generated-data benchmark and regression checks for title-cache invalidation and notification filtering.

## 1.1.0 — 2026-10-16

- English and Simplified Chinese interfaces, selected automatically from macOS preferences.
- A persistent **Follow system / 简体中文 / English** option with immediate updates.
- Localized menu bar text, live details, daily history, cost explanations, tooltips, and error messages.
- User-written chat titles and agent names retain their original text; language changes do not change statistics.
- Localization resource and formatting checks added to the test suite.

## 1.0.9

- Recognize logged Standard / Fast settings independently for the main agent and subagents.
- Estimate costs using the setting associated with each request's output boundary.
- Show Standard, Fast, and unknown / unsupported call coverage.
- Preserve unknown modes and mark unpriced requests explicitly.

## 1.0.8

- API-equivalent cost estimates by day and model, including supported cache and long-context rates.
- Show pricing coverage and the priced portion when some calls cannot be estimated.

## 1.0.7

- Daily input, output, reasoning, cache hits, models, and weighted output speed.
- Historical local and archived chats, incremental loading, and coverage warnings.

## 1.0.6

- Two menu bar rows for all active chats and the selected chat.
- Active subagent counts, individual details, and optional aggregation.

## Earlier versions

Log-based timing, continuous-output estimates, first-text latency, chat-title lookup, window placement fixes, a floating sidebar, and CSV export.

Detailed original Chinese notes are preserved in [README.txt](README.txt).
