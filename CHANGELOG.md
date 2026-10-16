# Changelog

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
