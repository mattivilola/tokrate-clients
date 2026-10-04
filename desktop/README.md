# Tokrate desktop — Windows and Linux development

Tauri 2 uses the system webview, a Rust monitor, and a small TypeScript dashboard. The native Swift Mac release remains unchanged. This client is version **0.1.10, pre-release development**; do not advertise stable platform support until the acceptance checklist passes.

## Build

Install [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/), Rust stable and Node 22+. Linux additionally needs the Secret Service DBus development library (`libdbus-1-dev` on Ubuntu).

```
cd desktop
npm ci
npm test
npm run build
cargo test --manifest-path core/Cargo.toml
cargo test --manifest-path src-tauri/Cargo.toml
npm run tauri -- build
```

Platform installers are built on their own OS by `.github/workflows/desktop.yml`. When `TAURI_SIGNING_PRIVATE_KEY` is available, CI produces updater-signed artifacts; pull-request builds without that secret remain unsigned test builds and are never published as releases. Windows NSIS and Linux AppImage installations can check the fixed alpha update feed and install only after the user clicks. Debian package installations use the manual download action because their privileged package replacement path has not been validated end to end. Local caches/target folders must not be committed. Keep Cargo and npm lockfiles once resolved. For a development UI server, use Portly as specified in root AGENTS.md. `npm run tauri -- dev` attaches to the managed preview at port 51719; it does not launch a second Vite process.

The browser preview labels its synthetic data and cannot upload it. A normal native launch uses real local logs and follows saved sharing preferences (new installation default ON). Update checks have a separate saved preference (new installation default ON); they never install without a click. Use the isolated smoke mode for automated tests:

```
python3 scripts/native-smoke.py src-tauri/target/release/tokrate-desktop
```

On Windows use the `.exe` suffix; on headless Linux wrap this in `xvfb-run -a dbus-run-session --`. The app requires an explicit temporary smoke directory, disables sharing and updater networking even if a command attempts to enable them, uses generated fixture logs, and exits after the webview validates parsed metrics. No production test data is sent.

## Boundaries

- `core`: Codex rollout JSONL, Claude Code transcript JSONL and Grok Build session event/usage logs; normalized history, bounded monitors and signed samples/queue; independent of Tauri.
- `src-tauri`: credential manager, filesystem root, fixed HTTPS endpoints, network cancellation, native lifecycle and tray. Only normalized metrics reach the UI.
- `ui`: exact source/parser/metric/model/provider/version/effort cohorts, coding-tool and provider filters, independent throughput/TTFT coverage, charts with gaps and local baselines. Claude and Grok do not report TTFT; their throughput definitions stay separate. No chart library, remote font, analytics SDK or browser-fetch transport.
- Sharing OFF clears the queue and community results, cancels the network task and prevents further identity/network work. Requests already transmitted cannot be recalled.
- Windows Credential Manager / Linux Secret Service hold signing keys. No plaintext-key fallback. Locked/unavailable credentials leave local monitoring operational; Retry starts a new future-only reporting period.
- Public API schema remains v1. Codex reports parser `codex-rollout-v1` / metric `turn-v1`; Claude Code reports `claude-transcript-v1` / `claude-observed-turn-v1`; Grok Build reports `grok-session-v1` / `grok-observed-work-turn-v1`. New adapters only share samples completed after consent and report no TTFT. The backend must accept 0.1.10 before upload testing with real observations.

## Remaining release acceptance

Record real Windows 11 and Linux GNOME/KDE desktop checks, key persistence/locked-store recovery, tray visibility/close/reopen/quit, high DPI/keyboard navigation, WSL/custom-folder behavior, idle CPU/RSS and installer upgrade/uninstall. CI native smoke covers startup/webview/fixture parsing; it is not a claim that every desktop integration passed. Windows Authenticode signing needs a separate verified signing arrangement. Resolve the service's existing legal/privacy launch findings before broad distribution. The full plan is in the private app repo `docs/WINDOWS_LINUX_PLAN.md`.
