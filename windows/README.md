# Tokrate for Windows

The Windows client is implemented in [`../desktop`](../desktop), sharing its Rust core and dashboard with Linux. An [alpha with installable packages and signed updates](https://github.com/mattivilola/tokrate-clients/releases/tag/v0.1.11-desktop-alpha.1) is available. Automated native checks passed; manual desktop acceptance is pending. No stable Windows release is published yet.

Target: Windows 11 x64 with Microsoft Edge WebView2. CI builds a per-user NSIS installer and runs the actual executable with isolated fixture logs and sharing disabled. Updater-enabled release artifacts carry a Tauri update signature. The installer is not Authenticode-signed and may show Windows first-install warnings; the Mac certificate cannot sign Windows programs.

Codex sessions default to `%USERPROFILE%\.codex\sessions`, or `$CODEX_HOME/sessions` when configured. For Codex inside WSL, choose the corresponding distribution's sessions folder using **Settings → Choose session folder**. WSL permissions/path behavior still needs desktop acceptance testing.

Click the tray icon or **Open dashboard** to see the gauge, model/effort selector, 24h/7d charts, local comparisons and sharing toggle. Windows tray icons do not support adjacent text: optional speed appears in the tooltip and tray menu. Closing the dashboard hides it to the tray; **Quit Tokrate** stops the app. Launching again reopens the existing instance.

The signing key is stored in Windows Credential Manager. Sharing requires affirmative first-launch consent from 0.1.11 and remembers OFF; while OFF the app performs no community requests. Read the root README/privacy information and desktop test/release gates before distributing.


The 0.1.9 source also monitors Claude Code (`CLAUDE_CONFIG_DIR/projects`, default `.claude/projects` in your home directory) and Grok Build (`GROK_HOME/sessions`, default `.grok/sessions`). The 0.1.18 source also monitors Antigravity (the desktop app, IDE and `agy` CLI): it reads the per-conversation SQLite databases under `.gemini` in your home directory (`antigravity`, `antigravity-ide` and `antigravity-cli` `conversations` folders) read-only, and bundles SQLite so no extra system library is needed. The dashboard distinguishes coding tool from inference provider and labels each measurement definition. Source-specific folder settings support nonstandard installations. See [the shared contract](../docs/metrics-contract.md); native CI evidence does not establish interactive acceptance on every desktop configuration.

## Software updates

Version 0.1.10 checks the separate desktop alpha channel automatically, independently of community sharing. You choose when to install; automatic checks can be disabled in Settings. NSIS installations verify the package signature before installing. Earlier versions need one manual installation of 0.1.10. Native CI passed; a real desktop upgrade from one updater-enabled release to the next has not yet been validated.
