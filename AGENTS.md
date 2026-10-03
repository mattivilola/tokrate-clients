# Tokrate clients

Keep macOS SwiftUI and the Windows/Linux Tauri client aligned with docs/metrics-contract.md. Never describe completed-turn throughput as streaming speed. Keep raw Codex content and signing keys outside the webview; persisted OFF must prevent credential access and community network requests. Do not publish a platform release based only on cross-compilation.

## Development servers

- Always use Portly (`portly ...`) for persistent local development servers.
- Start with `portly status --json`; reuse a healthy managed server.
- Never launch persistent development servers directly or through another supervisor.
