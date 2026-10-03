# Tokrate clients

Tokrate is a local macOS menu bar app and command-line inspector for completed-turn metrics from Codex session JSONL files. It reads Codex's local session logs only after you choose **Start monitoring**. It makes no network requests while sharing is off and does not retain prompt or response text.

The macOS app shows a seven-day history chart and per-turn rows. Its throughput metric is Codex-reported output tokens divided by whole-turn duration, including tool work and waits. The app labels Codex's reported TTFT separately; streaming-only tokens per second remain unavailable.

## Build

Requires macOS 14 or newer and Swift 6.

```sh
swift build
swift test
```

To stage and launch the menu bar app as a macOS bundle, run `./script/build_and_run.sh`. The script builds `dist/Tokrate.app` first. The command-line client is available with `swift run tokrate inspect <session.jsonl>`.

## Local data

The app reads `~/.codex/sessions` after Start monitoring, or a folder you select. Pausing stops reads. Completed-turn metrics are stored in Application Support and retained for seven days. See [the metrics contract](docs/metrics-contract.md) for fields, definitions, and privacy boundaries.

## Optional community sharing

The app launches as a menu-bar utility. Choose **Open dashboard** for the local chart, recent turns, and sharing controls. Monitoring and sharing are separate explicit actions and start off on each launch. Pausing monitoring leaves already-queued sharing active; turn **Share new turns** off to stop all community requests.

After confirming **Enable sharing**, the app creates or reuses a random Ed25519 identity in the macOS Keychain and sends only new completed-turn measurements to `https://tokrate.dev/api/public/v1/samples`. The public key identifies this installation pseudonymously; no account registration is required. The server sees the source IP during each connection. Community statistics and alerts are fetched only while sharing is enabled, at most every 30 seconds.

Uploads contain model/provider, source kind, client/app/parser/metric versions, output and reasoning counts, whole-turn duration, optional Codex-reported TTFT, a five-minute UTC time bucket, and a random sample UUID. They never contain prompts, responses, code, paths, session/account IDs, or the local deduplication hash. Historical turns are never backfilled. Turning sharing off cancels the network loop, clears pending uploads, and immediately hides community statistics. Already-received samples cannot be recalled by this switch. The installation key remains in Keychain for reuse.

Offline retries use a memory-only queue capped at 1,000 samples and 24 hours; quitting loses that queue. Retries retain the random sample UUID and sign a fresh request timestamp. Requests use an ephemeral URL session without cookies/cache and reject redirects. Local history is retained for seven days, capped at 50,000 turns. Recent files are read incrementally outside the main actor, with a 1 MiB per-poll budget and bounded parser state. Local history contains only normalized numeric/timestamp/version/model fields and a SHA-256 deduplication pseudonym, never the raw session/turn identity.

## Release packaging

```sh
./script/package_app.sh release
```

This builds a native-architecture `dist/Tokrate.app` (macOS 14+, bundle ID `dev.tokrate.mac`, version 0.1.1). It does not sign, notarize, publish, or launch. Release ownership must separately sign with Developer ID and hardened runtime, verify, submit and staple notarization, then archive the final bundle. `./script/build_and_run.sh --verify` stages a debug bundle and checks the launched process. Building again replaces bundle contents; sign only after the final build. The package has no third-party dependencies.

Validation: `swift test --build-system native -j 2` exercises parser timing, cumulative counts, malformed input, incremental file reading, retention, no requests/identity before consent, allowlisted signed bytes, five-minute buckets, no historical backfill, stable retries, polling rate limits, bounded queue expiry, and opt-out during a suspended upload. Tests use mocks and do not contact production.

To sign the already-built bundle, use `./script/sign_release.sh "$DEVELOPER_ID_IDENTITY"`. The script applies hardened runtime and a secure timestamp, verifies the signature, and stages `dist/Tokrate-0.1.1-macos-arm64.zip` on Apple Silicon. It adds no entitlements. To additionally submit, wait for acceptance, staple, verify Gatekeeper, and recreate the final archive, pass an already-configured Keychain notary profile as the second argument. No credential value belongs in the repository. The archive hash changes after stapling; publish only the final verified archive. In an environment that blocks SwiftPM's nested sandbox, `./script/package_app.sh release --disable-sandbox` uses the same local build without SwiftPM's inner sandbox.

Version 0.1.1 replaces the automatically updating relative timestamp in the native menu with a static completion timestamp. This avoids recursive SwiftUI menu refreshes observed with saved turn history.
