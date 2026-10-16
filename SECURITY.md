# Security and privacy reports

Codex Speed reads local conversation logs, so reports should avoid exposing their contents. Do not attach authentication files, tokens, full session logs, prompts, or private workspace paths to an issue.

For an ordinary bug, use a generated example and include app / macOS versions. For a suspected vulnerability, use GitHub's private **Report a vulnerability** option if available. Otherwise, open an issue requesting a private disclosure channel without posting exploit details or sensitive files.

The app does not require an API key or read authentication credentials. It builds usage history in memory and stores only preferences and the selected log-folder path. CSV exports are created only at the location selected by the user.
