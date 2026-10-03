# Tokrate for Linux

The Linux client is implemented in [`../desktop`](../desktop), sharing its Rust core and dashboard with Windows. It is under development; no stable Linux release is published yet.

Initial target: x64 Ubuntu 22.04-compatible systems, `.deb` and AppImage. The application uses WebKitGTK 4.1 and Ayatana AppIndicator; community sharing additionally requires a running, unlocked Secret Service (for example GNOME Keyring or compatible KDE service). Missing/locked credential storage shows a recoverable error; no private signing key is saved as plaintext. Local monitoring still works.

Codex sessions default to `~/.codex/sessions`, honoring `$CODEX_HOME`, with a settings folder picker. CI builds native packages and runs an isolated WebKitGTK fixture smoke test under Xvfb/DBus. GNOME/KDE and X11/Wayland integration still needs interactive acceptance.

Tray behavior varies. GNOME may need an AppIndicator extension. Use the tray's **Open dashboard** menu; left-click and tooltip behavior are not consistent across Linux desktop environments. A dashboard stays available on desktops without a tray host. Speed uses the indicator title where supported, with a tray-menu fallback. Closing minimizes to the taskbar so a missing indicator host cannot strand the app; **Quit Tokrate** stops the app.

A fresh install defaults sharing ON and remembers OFF. The local gauge/history work with sharing OFF, and no community request is made while OFF. Read the root README and service privacy information before distribution; the existing legal launch gates remain open.
