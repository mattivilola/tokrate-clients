# Tokrate client security and privacy review prompt

This is the exact prompt Tokrate gives to AI reviewers. Anyone can run it against the public repository and compare their result with the published ones. Only the **Target** block changes between reviews.

Run it with the reviewer in read-only mode, in any checkout of the repository whose code matches the target commit: your existing local checkout (only documentation changes since the target are allowed), or a fresh clone:

```sh
git clone https://github.com/mattivilola/tokrate-clients tokrate-review
cd tokrate-review
git checkout --detach cf4b743319f665c04da574f674f7f9de8c15405b
```

The prompt itself checks that the code matches and stops otherwise. Everything below the line is the prompt.

---

You are an independent security and privacy reviewer. Review the source code of the Tokrate desktop clients and decide whether the code keeps the privacy and security promises listed below. You are not the author and you have no reason to be generous: report what the code actually does.

## Target

- Repository: https://github.com/mattivilola/tokrate-clients
- Ref: Tokrate 0.1.20 (Mac `v0.1.20` and Windows/Linux `v0.1.20-desktop-alpha.1`, both from this commit)
- Commit: `cf4b743319f665c04da574f674f7f9de8c15405b`

Before starting, run these in the working directory:

```sh
git cat-file -e cf4b743319f665c04da574f674f7f9de8c15405b^{commit}
git diff --quiet cf4b743319f665c04da574f674f7f9de8c15405b -- . ':(exclude)*.md'
```

The first confirms the commit exists; the second confirms that every tracked non-Markdown file in the working directory, including uncommitted changes, is identical to the target commit. If either exits non-zero, stop and return only `{"error": "code does not match target", "head": "<output of git rev-parse HEAD>"}`.

Only files tracked at the target commit are in scope (`git ls-tree -r --name-only cf4b743319f665c04da574f674f7f9de8c15405b`). Ignore untracked and gitignored files, including build output and installed dependencies (`.build/`, `desktop/**/target/`, `node_modules/`, `dist/`, `.local/`); review dependencies through the lock files instead. For Markdown files, read the version at the target commit (`git show cf4b743319f665c04da574f674f7f9de8c15405b:README.md`).

## What Tokrate is

Tokrate is a menu-bar / tray app that reads the local session logs of AI coding tools (Codex, Claude Code, Grok Build, Antigravity, OpenCode), measures how fast the model answered, and, only if the user opts in, uploads the numbers (model, token counts, timings) to `tokrate.dev` for a public speed board.

Two implementations are in scope. Check every claim against both:

- **macos**: the Swift app. `shared/` (core, parsers, sharing, CLI `tokrate`) and `macos/` (SwiftUI app, packaging scripts).
- **windowsLinux**: the Tauri app. `desktop/core` (Rust core), `desktop/src-tauri` (native host), `desktop/ui` and `desktop/*` frontend and build config.

Also in scope: `Package.swift`, `Package.resolved`, `desktop/**/Cargo.toml`, `desktop/**/Cargo.lock`, `desktop/package*.json`, `.github/workflows/`, the updater public keys, and packaging/signing scripts (look for secrets or unsafe build steps).

Out of scope: the tokrate.dev backend, which is not in this repository. Server-side promises (retention, IP handling, continent derivation) cannot be checked here; do not mark them as failures.

## Rules

1. **Code is the only evidence.** README, `docs/`, comments, identifiers and test names describe intent; they are not proof. Use them to find what to check, then confirm in the code that runs. Tests may support a verdict but never replace reading the implementation.
2. **Trace data end to end.** For uploads, follow a value from the file or database it is read from, through parsing, storage and serialization, to the network call. For each claim, look for any code path that breaks it, not only the main path.
3. **Find every network call, file write and log call yourself.** Search for networking APIs (for example `URLSession`, `URLRequest`, `reqwest`, `ureq`, `hyper`, `fetch`, `XMLHttpRequest`, Tauri HTTP/updater plugins, Sparkle), file writes, process launches, and logging (`print`, `NSLog`, `os_log`, `Logger`, `println!`, `eprintln!`, `log::`, `tracing::`, `console.*`).
4. **Check dependencies.** Read `Package.resolved`, `Cargo.lock` files and `desktop/package-lock.json` for analytics, crash-reporting, advertising or telemetry packages, and check what any network-capable dependency is used for.
   Third-party dependency source code (Sparkle, Tauri and its updater plugin, reqwest, SQLite, notify and so on) is not in this repository. Judge how the app configures and calls a dependency, and take a well-established dependency's documented behaviour as given (for example that Sparkle verifies the EdDSA signature against `SUPublicEDKey` before installing, or that the Tauri updater verifies the minisign signature against the configured `pubkey`). Do not mark a claim `NOT_VERIFIABLE` only because that code is not in the repository; list the dependency behaviour you relied on in `scope.limitations`. A claim is `NOT_VERIFIABLE` only when this repository's own code or configuration leaves the outcome open.
5. **Cite exact locations.** Every evidence item needs a repository-relative path and the line numbers at the target commit. Do not cite files you did not open. Never invent a path or line.
6. **No speculation as findings.** A finding needs a concrete code path. Hardening ideas without a current defect are `info`.
7. **Read-only.** Do not modify, build-install, or run the apps. Running the test suites (`swift test`, `cargo test`) is allowed but optional. Do not contact tokrate.dev or any other service, and do not use web search.
8. **Be complete before concluding.** If you could not examine something, list it in `scope.notExamined`; do not guess its verdict.

## Claims to check

Check each claim, use its exact ID, and keep the order.

- **C01 Upload allowlist.** Each community upload is built from an explicit field allowlist and contains only the fields documented in `README.md` (section "Optional community sharing") and `docs/metrics-contract.md`. It never contains prompts, responses, code, file or folder paths, session/turn/account identifiers, the local deduplication digest, raw originator/entrypoint strings, user names, host names or hardware identifiers. List every key actually sent in `uploadedFields`, and report any key the documentation does not mention.
- **C02 Content is not retained.** Parsers keep only numeric usage, timestamps, model/provider identifiers, reasoning effort and the documented category fields. Prompt and response text, tool output, code and paths are not stored beyond parsing. Sources the documentation says are never read are really never opened or queried: Grok `chat_history.jsonl` and `updates.jsonl`; the OpenCode `part` table and full `message.data`; Antigravity `step_payload`, `trajectory_metadata_blob`, `render_info`, `task_details`, `permissions`, `error_details`, `battle_mode_infos`.
- **C03 Minimal local storage.** Local history stores only normalized metric records and checkpoints (with SHA-256 path digests, never raw paths or raw session/turn identifiers). Records are kept for 7 days and at most 50,000 turns while the app runs; expired records are removed within about an hour, also while monitoring is paused (nothing runs while the app is not running). Live per-response values are memory only.
- **C04 Read-only access to coding-tool data.** The app never writes, modifies, deletes or renames other tools' session files or databases, and never takes an exclusive lock on them. SQLite databases are opened read-only (`mode=ro`, never `immutable=1`); SQLite's normal shared lock for the duration of a short read transaction is expected and does not break this claim.
- **C05 Affirmative consent.** No sample is uploaded and no community request is made until the user explicitly opts in on the current notice version. "Only for local use" and a saved OFF stay OFF across launches and upgrades. Raising the notice version requires a new opt-in.
- **C06 Consent screen is accurate.** The sample payload and field description the consent screen shows match the structure and fields that are actually uploaded.
- **C07 Sharing OFF stops network activity.** Switching sharing off cancels the upload loop, clears pending uploads and stops community statistics/alert fetches. While sharing is off, no request is made to the community endpoints.
- **C08 No backfill.** Only turns completed after the current launch or the latest switch-on are eligible for upload; historical turns are never uploaded.
- **C09 Pseudonymous identity.** The installation identity is a random Ed25519 key stored in the OS credential store (macOS Keychain, Windows Credential Manager, Linux Secret Service). Only the public key and signatures are sent; the private key never leaves the store or the process. No user name, host name, hardware/device identifier, MAC address or serial number is collected or sent.
- **C10 Known network destinations only.** All network requests go to `tokrate.dev` (sample upload, community statistics, update feeds) or GitHub (update packages), over HTTPS. Update packages are accepted only from this repository's GitHub release assets; update requests may follow ordinary HTTP redirects (GitHub serves release assets from its own download hosts), which is documented and expected, provided packages are installed only after signature verification. Sharing requests reject redirects and use no cookies or persistent cache. No other host is contacted, and local-only features (history export, `tokrate inspect`) make no network requests. List every request in `networkEndpoints`.
- **C11 No tracking SDKs.** No analytics, advertising, crash-reporting or telemetry SDK is included in any dependency set, and no separate install, launch or usage event is sent.
- **C12 Update integrity and privacy.** Updates are verified against public keys embedded in the app before installation (Sparkle EdDSA on Mac, Tauri updater minisign on Windows/Linux), and installation requires a user action. Update checks send no contribution key, measurements or coding-tool content. Sparkle system-profile reporting is disabled. The automatic-check switch is respected.
- **C13 Bounded memory-only queue.** Unsent uploads are held only in memory, capped at 1,000 samples and 24 hours, and are lost on quit. Nothing pending is written to disk.
- **C14 No sensitive logging.** No prompts, responses, paths, session identifiers, keys or signatures are written to logs, the console, the OS log or crash output.
- **C15 No remote code or content.** The app UI loads no remote web content and executes no downloaded code other than signed updates. On Windows/Linux the Tauri content security policy and capabilities limit the frontend to what it needs, and the IPC commands it exposes cannot read arbitrary files or reach arbitrary network destinations (fixed-purpose commands such as an update check or switching sharing on, which reach only the endpoints of C10, are expected).
- **C16 Upload timing.** A sample is uploaded only after its five-minute `observedAt` period has ended, after a random delay, so neither the request's `sentAt` nor its sending time places a turn more precisely than its five-minute period. Community statistics fetches do not reveal when turns completed.

## Threat model

Use this to judge who can trigger a defect, and set severity accordingly:

- **The tokrate.dev service and anyone on the network path** see every request. What can they learn about the user beyond the documented fields? Could they make the app do something harmful (responses, update feeds)?
- **Content inside the coding tools' logs and databases** (prompt, response and tool-output text) can be influenced by third parties, for example a malicious repository, web page or model output. A defect triggerable by such content is realistic.
- **File structure** (file types such as FIFOs or symlinks, numeric fields, timestamps, JSON shape, file sizes, paths) is written by the coding tools themselves. Crafting it requires write access to the user's home folder; such an attacker can already do far more than disturb Tokrate.
- **Other local users** on the same machine, through file permissions.

## General security review

Beyond the claims, report concrete defects in any area, for example:

- Handling of untrusted input: the session files and databases Tokrate reads are written by other programs and could be crafted. Look for crashes, unbounded memory or CPU use, path traversal, symlink following outside source roots, SQL injection, and unsafe deserialization.
- Request signing and replay: signature construction, timestamp handling, key generation randomness.
- Local file permissions and locations of the history file and any other written file.
- Tauri IPC surface, webview configuration, CSP gaps.
- Secrets, private keys or credentials committed to the repository; unsafe CI or packaging steps.
- Places where the documentation promises something the code does not do (severity by user impact).

## Severity

- `critical`: prompts, responses, code, paths or the private key can leave the device, or remote code execution is possible.
- `high`: a claim is contradicted in normal use; data leaves without consent; update verification can be bypassed.
- `medium`: a claim fails only in an edge case or on one platform; a defect exploitable by the service, a network observer, another local user, or content inside the coding tools' logs; documentation materially misstates what is sent or stored.
- `low`: a defense-in-depth gap with limited impact; a crash, hang or resource exhaustion that needs crafted file structure (write access to the user's home folder, see Threat model); a minor documentation inaccuracy.
- `info`: an observation or hardening suggestion with no current defect.

## Verdicts

Per claim and per implementation:

- `VERIFIED`: the code implements the claim on every path you traced, with evidence cited.
- `PARTIAL`: the claim holds in general but has a gap (an edge case, one path, a documentation mismatch). Must reference at least one finding.
- `CONTRADICTED`: the code does what the claim says it does not do. Must reference a finding of severity `high` or `critical`.
- `NOT_VERIFIABLE`: the source cannot settle it; explain why in `rationale`.
- `NOT_APPLICABLE`: the claim does not apply to this implementation (explain why).

The claim's overall `verdict` is the worse of its two implementation verdicts, in this order from worst: `CONTRADICTED`, `PARTIAL`, `NOT_VERIFIABLE`, `VERIFIED`. `NOT_APPLICABLE` is ignored unless both are `NOT_APPLICABLE`.

`summary.overallVerdict`:

- `FAIL` if any claim is `CONTRADICTED` or any finding is `critical` or `high`;
- otherwise `PASS_WITH_NOTES` if any claim is `PARTIAL` or `NOT_VERIFIABLE`, or any finding is `medium`;
- otherwise `PASS`.

## Output format

Your final answer must be exactly one JSON object that matches the schema below: no Markdown fences, no text before or after it. Use only the enum values given. Keep string lengths within the stated limits. Use `[]` for empty lists and `null` for unknown optional values. Number findings `F01`, `F02`, … from most to least severe.

```jsonc
{
  "schemaVersion": "tokrate-client-review/1",
  "reviewer": {
    "model": "string — exact model name and version you are",
    "tool": "string — agent or app you ran in, e.g. Codex CLI, Claude Code, Grok",
    "reviewedAt": "YYYY-MM-DD"
  },
  "target": {
    "repository": "https://github.com/mattivilola/tokrate-clients",
    "ref": "v0.1.20",
    "commit": "the 40-character target commit SHA you verified"
  },
  "scope": {
    "filesExamined": 0,                    // integer: files you actually opened
    "testsRun": "none | swift | cargo | swift+cargo",
    "notExamined": ["string ≤ 160 chars"],
    "limitations": ["string ≤ 200 chars"]
  },
  "summary": {
    "overallVerdict": "PASS | PASS_WITH_NOTES | FAIL",
    "headline": "string ≤ 160 chars — one plain-language sentence for a website visitor",
    "claimCounts": { "VERIFIED": 0, "PARTIAL": 0, "CONTRADICTED": 0, "NOT_VERIFIABLE": 0, "NOT_APPLICABLE": 0 },
    "findingCounts": { "critical": 0, "high": 0, "medium": 0, "low": 0, "info": 0 }
  },
  "claims": [                              // exactly 16 entries, C01 … C16 in order
    {
      "id": "C01",
      "verdict": "VERIFIED | PARTIAL | CONTRADICTED | NOT_VERIFIABLE | NOT_APPLICABLE",
      "byImplementation": {
        "macos": "VERIFIED | PARTIAL | CONTRADICTED | NOT_VERIFIABLE | NOT_APPLICABLE",
        "windowsLinux": "VERIFIED | PARTIAL | CONTRADICTED | NOT_VERIFIABLE | NOT_APPLICABLE"
      },
      "confidence": "high | medium | low",
      "rationale": "string ≤ 600 chars — what you traced and why the verdict follows",
      "evidence": [ { "file": "repo/relative/path", "lines": "120-148", "note": "string ≤ 160 chars" } ],
      "findings": ["F01"]
    }
  ],
  "uploadedFields": [                      // every JSON key in an upload request body, both implementations
    {
      "field": "string — JSON key as sent",
      "type": "string | integer | number | boolean | null-able variants, e.g. integer|null",
      "valueSource": "string ≤ 160 chars — where the value comes from",
      "implementations": ["macos", "windowsLinux"],
      "documented": true,
      "containsUserContent": false
    }
  ],
  "networkEndpoints": [                    // every outbound request either app can make
    {
      "url": "string — scheme, host and path (use {placeholder} for variable parts)",
      "method": "GET | POST | PUT | other",
      "purpose": "string ≤ 120 chars",
      "when": "string ≤ 160 chars — what triggers it and whether sharing/update switches gate it",
      "sends": "string ≤ 200 chars — headers and body contents that could identify the user or install",
      "implementations": ["macos", "windowsLinux"],
      "evidence": [ { "file": "repo/relative/path", "lines": "10-42", "note": "string ≤ 160 chars" } ]
    }
  ],
  "findings": [
    {
      "id": "F01",
      "severity": "critical | high | medium | low | info",
      "category": "privacy-leak | consent | network | local-storage | input-handling | resource-exhaustion | crypto | update-integrity | supply-chain | ipc-webview | logging | secrets | documentation | other",
      "title": "string ≤ 100 chars",
      "description": "string ≤ 800 chars — the defect and the concrete code path",
      "impact": "string ≤ 300 chars — what can actually happen to a user",
      "recommendation": "string ≤ 400 chars",
      "implementations": ["macos", "windowsLinux"],
      "claims": ["C05"],
      "evidence": [ { "file": "repo/relative/path", "lines": "55-61", "note": "string ≤ 160 chars" } ]
    }
  ]
}
```
