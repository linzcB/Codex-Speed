# How measurements work

[简体中文](STATISTICS.zh-CN.md) · [Back to the app](../README.md)

## Live speed

| Metric | Calculation | Limits |
| --- | --- | --- |
| Continuous output | Timed output tokens ÷ recorded output-segment duration | Excludes pre-output waits and tools between segments. Includes reasoning and generated tool arguments. Segment starts are not exact first-token timestamps. |
| Without tools | Recorded output ÷ turn time after recorded tool intervals are removed | Still includes network, input processing, and other waits. |
| Whole-turn average | Recorded output ÷ elapsed turn time | Includes tools and waits. |

The menu bar's top row adds the speeds of all active chats. Its bottom row shows the chat selected in the panel. With subagents enabled, each participating agent is timed independently and its valid live speed is added.

An active agent has an unfinished latest turn and log activity within the last **five minutes**. Agents without usable timing do not contribute a speed sample. A dash means insufficient samples, not zero output. Inactive subagent history can still contribute to token totals when subagents are enabled.

## Latency

- **First-text latency (estimated):** time from turn start to the logged start of the first visible answer segment. Reasoning is not treated as visible text.
- **First-token latency (logged):** Codex's `time_to_first_token`, when recorded at turn completion. This may refer to reasoning, so it can differ from first-text latency.

## Daily history

Calls are assigned to the date of their usage record in the displayed local time zone. Independent chats, subagents when enabled, and archived local chats are included. Per-request usage is counted once; copied parent history and cumulative thread totals are not added again.

**Average speed = total timed output tokens ÷ total corresponding output time.** Agent durations are added separately even when they overlap. This average differs from the sum of live speeds; it is not a simple average of displayed rates. Calls without reliable timing retain their usage but do not contribute to speed.

**Cache hit rate = cached input tokens ÷ input tokens from calls with cache data.** Cached input is already part of input totals. Missing cache fields are not treated as zero hits. The UI shows cache-data and timing coverage.

## Cost estimates

API-equivalent estimates use the supported price catalog and each request's recorded Standard/Fast setting, including supported long-context adjustments. Each agent's own settings are used. Unknown modes, unsupported models, and incomplete pricing data remain unpriced; the UI shows the priced portion and coverage.

The latest settings do not retrospectively reprice older calls. Logged settings do not prove the actual server tier or whether a Fast request was downgraded. Estimates do not represent subscription charges or confirmed API bills. The catalog's date and official pricing links appear in the app.

## Coverage

The app reads local logs. Cloud-only and unavailable remote logs cannot be reconstructed from chat text or the workspace folder. Initial scans and incomplete records can temporarily reduce coverage; the UI reports those conditions.

Chat titles, model identifiers, aggregation keys, and CSV column names keep their original values when the interface language changes.
