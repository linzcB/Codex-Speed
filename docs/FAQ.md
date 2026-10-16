# Frequently asked questions

[简体中文](FAQ.zh-CN.md) · [Back to the app](../README.md)

### Where is the app window?

Codex Speed is a menu bar app and has no Dock icon. Click its two-line readout for details. Use the pin button to keep the panel visible. Right-click the readout for its menu, including Quit.

### Why is my cloud chat missing?

The app needs local session logs containing usage and timing. A downloaded workspace, chat content, or an account-wide usage total does not provide the required per-request records. See [coverage](STATISTICS.md#coverage).

### Why do the numbers differ from Codex's account usage?

This app measures the local logs it can read. Codex account totals may cover other hosts and cloud chats. Displayed cost coverage, timing coverage, unknown modes, and loading warnings explain further gaps. A useful comparison must use the same dates, time zone, chats, agents, and token categories.

### Does it follow the chat selected in Codex?

Choose a chat in the panel. Automatic mode follows recent log activity; it does not inspect the selected Codex window.

### Does switching off subagents hide their details?

No. Their details remain available, while their speeds, tokens, daily usage, and costs are excluded from the selected aggregation.

### Is the cost estimate my bill?

It is an API-equivalent estimate using supported published prices and logged mode settings. Unknown or incomplete calls are left unpriced. It does not measure your subscription charge or confirm the server's actual billed tier.

### Why does macOS block opening the app?

The current build is ad hoc signed and is not notarized. Review the source, release checksums, and [Apple's guidance](https://support.apple.com/guide/mac-help/mh40616/mac) before choosing whether to allow it. No command to disable system-wide protections is required by this project.

### Can I change languages?

Use **… → Language**. Follow system, 简体中文, and English are supported. The preference is saved; user-written chat titles and agent names remain unchanged.

### How often does it refresh?

Active monitoring and visible panels use a roughly one-second refresh. When idle with the panel hidden, file-system notifications wake the app for relevant log or title changes, with a 30-second fallback check. Full directory discovery has a 60-second recovery interval; new files and changes to older, untracked chats request discovery immediately. If notifications cannot start, one-second polling and ten-second discovery remain enabled.

Automatic daily-history scanning pauses when the panel is hidden. Reopening it refreshes the data. Unchanged menu bar text is not repainted.
