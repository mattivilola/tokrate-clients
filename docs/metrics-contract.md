# Tokrate local metrics contract

Version 1 is derived from the observed Codex session JSONL structure available in Codex 0.159.2. That event layout is not a stable public API. Unsupported and legacy `token_count` events are ignored.

## Source interpretation

- A record is emitted only for a completed `event_msg` / `task_complete` turn with a valid `turn_token_usage.output_tokens` total and a positive whole-turn duration.
- `outputTokens` is Codex's per-turn output token count and may include reasoning output. Repeated usage records are cumulative totals; Tokrate uses the latest reported total instead of adding them.
- `durationSeconds` uses Codex's `duration_ms`, or derives elapsed time from valid start and completion timestamps when the duration is null or missing.
- `turnThroughputTPS` is `outputTokens / durationSeconds`. It includes tool time, waits, and reasoning time, so it is a completed-turn throughput metric rather than generation speed.
- `codexTTFTSeconds` carries Codex's `time_to_first_token_ms` value. It is Codex-reported TTFT and does not claim first visible text timing.
- `streamingTPS` is always `null` until a verified generation-only source is available. Tokrate never subtracts tool duration to estimate it.
- A model is `null` when absent or when more than one model is observed during a turn. Agent sessions marked by `parent_thread_id` or `agent_path`, or a structured subagent source, are omitted to avoid silently combining subagent work.
- Incomplete/aborted turns, malformed lines, non-finite values, negative values, missing output totals, and invalid durations produce no record.

## JSON representation

`tokrate inspect <path>` emits only:

```json
{
  "schemaVersion": 1,
  "metrics": [
    {
      "id": "<64-character SHA-256 pseudonym>",
      "completedAt": "2026-10-03T10:00:10Z",
      "model": "example-model",
      "outputTokens": 200,
      "durationSeconds": 10,
      "codexTTFTSeconds": null,
      "turnThroughputTPS": 20,
      "streamingTPS": null
    }
  ]
}
```

The ID is a local SHA-256 digest of the session and turn identifiers for deduplication. Raw identifiers and source paths are never emitted or persisted. No prompts, response bodies, account fields, or other source event payload fields enter the normalized record. The native app's local file stores only this versioned metric record collection and prunes entries older than seven days. Optional metadata includes sanitized Codex client version, reasoning-output tokens, provider (`openai` or `unknown`), and source kind. Recognized CLI, VS Code/desktop, and exec sessions are primary; absent or unrecognized source metadata is unknown. Only explicit OpenAI provider metadata is classified as OpenAI.

Monitoring starts automatically on launch. From 0.1.11, sharing starts only after affirmative consent: “Yes, let's contribute” or “Only for local use”. Legacy ON without current consent requires reconfirmation; saved OFF remains OFF. Enabling presents the notice; disabling is immediate. Only turns completed after this launch or the latest successful enable/retry are eligible; old turns are never backfilled. Its JSON allowlist is defined in `SharedSample.swift`; it uses a random UUID instead of the local digest, rounds observation time down to a five-minute UTC bucket, and sends explicit nulls for missing numeric fields. See the README for saved preferences, queue, Keychain failure/retry, and request-lifetime behavior.

## Dashboard presentation

A persisted model/provider/Codex-version cohort selection scopes the gauge, rolling 24-hour / 7-day chart, summaries, history, menu-bar value and matching community data. The latest completed cohort is the initial selection. All models displays separate comparison rows without pooling a headline rate or slowdown signal. The static gauge shows the selected cohort’s latest eligible completed turn in the chosen range; it never measures live decoding. Summary medians use individual eligible turns, not chart-bucket averages. Throughput eligibility requires at least 20 output tokens. Median/min/max and sample counts are independent for throughput and reported TTFT; missing measurements stay unavailable. The full history table is bounded to 500 matching rows.

Personal baseline signals use last 24 hours versus the preceding six days within the exact cohort. Each metric independently requires 5 recent eligible measurements and a last observation within 60 minutes; its baseline requires 20 eligible measurements across at least two days. TTFT eligibility is independent of the throughput token minimum. Positive baseline medians are required. Throughput must decrease at least 30%, or TTFT increase at least 50% and one second. The UI labels insufficient/stale baselines and possible workload changes. This descriptive heuristic is separate from the public detector; no OS notifications or provider-intent inference is made. Recorded reasoning effort stays separate, while Fast/service mode and task complexity are not controlled, and model quality is not measured.

## Public aggregation and reporting counts

The payload is performance telemetry, not browsing or behavioral analytics. It excludes user content and account details. A stable random signing key makes contributions pseudonymous: the service stores the public-key hash with accepted samples, and retains a minimal hash/first-report/last-report registry for lifetime reporting-installation counts. No extra install beacon or tracking event is sent. Never-reporting installations cannot be counted. Samples expire after 30 days; the minimal registry persists and backups may retain data longer.

Normal aggregate publication requires 10 contributors and 50 eligible turns. The launch-only administrator-controlled Early data mode lowers publication coverage to one reporting installation and one eligible turn, with a public small-sample label. Such an aggregate may describe one installation; no contributor identity is published. The slowdown detector keeps its stricter coverage requirements.

Local summaries may include unknown-source turns preserved in local history; community comparisons use only reported primary-client samples. Explicit subagent sessions are excluded by the current parser.

## Explicit reasoning effort (0.1.6)

The parser reads only `turn_context.payload.effort` for the same turn ID. Allowed values are `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, and `ultra`. Missing, invalid or conflicting values become `unknown`. No inference uses reasoning-output tokens, global settings or Fast mode. Local decoding remains compatible with records that omit the optional field. New uploads include `reasoningEffort`; schemaVersion remains 1. Older server submissions without it normalize to unknown.

Local cohort selections now include effort; legacy three-part selections restore as unknown. Public cohort IDs retain model/provider/clientVersion/parserVersion/metricVersion first, followed by effort and coding client. The native client uses this exact scope for community comparisons.

## Decision summaries (0.1.7)

Local recent observations cover 15 minutes. A 24-hour comparison uses the immediately preceding 24 hours and needs five eligible measurements per period and a nonzero previous median before calculating percentage change. Throughput and TTFT eligibility are independent. The seven-day retention cannot support a previous seven-day comparison. These descriptive comparisons do not replace the personal slowdown detector.

Optional public cohort fields `recent`, `comparison`, and `signals` keep older cached responses decodable. Public periods end at the latest complete five-minute boundary and preserve model/provider/client version/parser/metric/effort identity. Community signals retain independent contributor floors even during early publication. Processing freshness does not imply recent observations or worldwide provider health; geography, quality and Fast mode remain unknown.

## Multiple coding tools (0.1.9)

`client` identifies the coding tool and is independent of inference `provider`. Carry `client`, `parserVersion`, and `metricVersion` in saved history and uploads; old records without them decode as Codex / codex-rollout-v1 / turn-v1. Exact local/community cohorts include model, provider, tool, source version, parser, metric and effort. Provider stays unknown absent explicit routing evidence; model family is not routing evidence.

| Tool | Parser | Metric | Scope |
| --- | --- | --- | --- |
| Codex | codex-rollout-v1 | turn-v1 | Existing completed-turn accounting |
| Claude Code | claude-transcript-v2 | claude-observed-turn-v1 | Human prompt through terminal response in the primary transcript; unique API message usage |
| Claude Code subagent | claude-transcript-v2 | claude-observed-subagent-turn-v1 | Subagent task prompt through its terminal response; sourceKind `subagent` |
| Grok Build | grok-session-v1 | grok-observed-work-turn-v1 | Matched completed work-turn events and usage; includes nested agent output |

Claude/Grok TTFT and streaming rate are null. Reasoning token details are not added to output tokens. Exclude ambiguous/incomplete windows rather than fabricate timing. Claude tool-result records are not human turn starts; deduplicate repeated content blocks by API message ID. Primary turns exclude sidechains; subagent transcripts are measured separately (0.1.12, below). Grok usage timestamps record persistence after completion: require exact session/unique turn-number joins, usage time from one second before to 60 seconds after completion, and no later than the next known primary start. The 60-second cap is a conservative Tokrate bound; incomplete/colliding/ambiguous joins are excluded, repeated snapshots are deduplicated, and child sessions are not separately counted. Grok model attribution requires exactly one modelUsage entry: older missing breakdowns stay Unknown even if a selected/primary model is recorded.

Default roots are `~/.claude/projects` (or `CLAUDE_CONFIG_DIR/projects`) and `~/.grok/sessions` (or `GROK_HOME/sessions`). Only source metadata and numeric usage are retained. Raw messages, paths, session IDs, diagnostic logs and auth data are never uploaded. The same saved OFF and future-only sharing behavior applies to all tools. Unknown geography/provider/model must not be presented as a provider health signal. Rates with different metric versions cannot be ranked interchangeably.

## Software update traffic

From 0.1.10, automatic software update checks are independently configurable and on by default. Sharing OFF still blocks contribution/board requests, not update requests. Updates use a fixed platform/channel feed, no contributor key or measurements, and embedded public-key signature verification. Sparkle system-profile reporting is disabled. Installation requires user action. UI, README and website must disclose the separate switch and ordinary infrastructure network metadata. Native fixture smoke must disable all updater network activity.

## Claude Code transcript v2 and subagent turns (0.1.12)

All Claude metrics emitted from 0.1.12 carry parser `claude-transcript-v2`. Records saved by earlier versions keep `claude-transcript-v1` and remain separate cohorts. The primary metric version stays `claude-observed-turn-v1`.

A turn starts at a human text user record and ends at the first assistant message with `stop_reason` `end_turn` or `stop_sequence`. Output tokens are summed over unique API message IDs across the whole turn. The v2 rules are:

- **Mid-turn messages.** A human text message sent while the turn is still active continues the turn: the original start time, accumulated messages, model, effort and client version are kept, and the turn identity stays the original prompt. It continues only if its timestamp is at most 30 minutes after the latest user or assistant record already consumed in that turn (tool-result records count as activity). Otherwise the stale turn is discarded and the message starts a new turn.
- **Interruptions.** A user record whose content (a string or a text block) starts with `[Request interrupted by user` discards the in-progress turn and does not start a new one.
- **Synthetic messages.** An assistant message whose model is `<synthetic>` (client-generated placeholder or error text) invalidates the turn. When that turn reaches a terminal stop reason it emits nothing. Synthetic messages never make the model ambiguous.
- **Meta records.** User records marked `isMeta` are ignored for turn starts and interjections.

Subagent transcripts (`<session>/subagents/agent-<id>.jsonl`) are read with the same turn rules but accept records marked `isSidechain: true`, `userType: external` and a safe `agentId` instead of the primary predicate. Their `.meta.json` files are not read; the model comes from assistant records. A subagent turn runs from the task prompt (or a later follow-up prompt, which is a separate turn) to its terminal response and includes tools and waiting. Metrics use client `claude-code`, parser `claude-transcript-v2`, metric `claude-observed-subagent-turn-v1`, sourceKind `subagent`, provider `unknown` and no TTFT. The local digest hashes `sessionId|agentId|userTurnUUID`, so subagent identities never collide with primary turns. The UI labels this metric "Subagent turn speed": subagent task prompt to final answer, including tools and waiting.

Subagent and primary turns are separate local cohorts (metric version and source differ) and are never pooled or ranked against each other. Subagent samples are shared exactly like primary ones, through the same allowlist with `sourceKind` `subagent`. The Mac app watches primary and subagent transcript files with two independent monitors under the same root, each with the existing live-tail/archive fairness, byte budgets and 2,000-file limit, so subagent files cannot starve primary monitoring.
