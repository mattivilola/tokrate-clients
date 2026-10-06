# Tokrate for Linux

The Linux client is implemented in [`../desktop`](../desktop), sharing its Rust core and dashboard with Windows. An [alpha with installable packages and signed updates](https://github.com/mattivilola/tokrate-clients/releases/tag/v0.1.11-desktop-alpha.1) is available. Automated native checks passed; manual desktop acceptance is pending. No stable Linux release is published yet.

Initial target: x64 Ubuntu 22.04-compatible systems, `.deb` and AppImage. The application uses WebKitGTK 4.1 and Ayatana AppIndicator; community sharing additionally requires a running, unlocked Secret Service (for example GNOME Keyring or compatible KDE service). Missing/locked credential storage shows a recoverable error; no private signing key is saved as plaintext. Local monitoring still works.

Codex sessions default to `~/.codex/sessions`, honoring `$CODEX_HOME`, with a settings folder picker. CI builds native packages and runs an isolated WebKitGTK fixture smoke test under Xvfb/DBus. GNOME/KDE and X11/Wayland integration still needs interactive acceptance.

Tray behavior varies. GNOME may need an AppIndicator extension. Use the tray's **Open dashboard** menu; left-click and tooltip behavior are not consistent across Linux desktop environments. A dashboard stays available on desktops without a tray host. Speed uses the indicator title where supported, with a tray-menu fallback. Closing minimizes to the taskbar so a missing indicator host cannot strand the app; **Quit Tokrate** stops the app.

A fresh install asks before sharing from 0.1.11 and remembers OFF. The local gauge/history work with sharing OFF, and no community request is made while OFF. Read the root README and service privacy information before distribution; the existing stable-release and legal launch gates remain open.


The 0.1.9 source also monitors Claude Code (`CLAUDE_CONFIG_DIR/projects`, default `.claude/projects` in your home directory) and Grok Build (`GROK_HOME/sessions`, default `.grok/sessions`). The 0.1.18 source also monitors Antigravity (the desktop app, IDE and `agy` CLI): it reads the per-conversation SQLite databases under `.gemini` in your home directory (`antigravity`, `antigravity-ide` and `antigravity-cli` `conversations` folders) read-only, and bundles SQLite so no extra system library is needed. It also monitors OpenCode (`$XDG_DATA_HOME/opencode`, default `.local/share/opencode` in your home directory, also on Windows): the `opencode.db` SQLite database is read read-only, with the same bundled SQLite; provider ids OpenCode records (gateways, vendor plans, local servers) stay on your device and such turns are never shared. The dashboard distinguishes coding tool from inference provider and labels each measurement definition. Source-specific folder settings support nonstandard installations. See [the shared contract](../docs/metrics-contract.md); native CI evidence does not establish interactive acceptance on every desktop configuration.

## Software updates

Version 0.1.10 checks the separate desktop alpha channel automatically, independently of community sharing. You choose when to install; automatic checks can be disabled in Settings. AppImage installations verify the package signature before installing. Debian installations open the download page for manual package-manager updates. Earlier versions need one manual installation of 0.1.10. Native CI passed; a real desktop upgrade from one updater-enabled release to the next has not yet been validated.
