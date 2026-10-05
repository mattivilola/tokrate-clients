# Tokrate local metrics contract

Version 1 is derived from the observed Codex session JSONL structure available in Codex 0.159.2. That event layout is not a stable public API. Unsupported and legacy `token_count` events are ignored.

## Source interpretation

- A record is emitted only for a completed `event_msg` / `task_complete` turn with a valid `turn_token_usage.output_tokens` total and a positive whole-turn duration.
- `outputTokens` is Codex's per-turn output token count and may include reasoning output. Repeated usage records are cumulative totals; Tokrate uses the latest reported total instead of adding them.
- `durationSeconds` uses Codex's `duration_ms`, or derives elapsed time from valid start and completion timestamps when the duration is null or missing.
- `turnThroughputTPS` is `outputTokens / durationSeconds`. It includes tool time, waits, and reasoning time, so it is a completed-turn throughput metric rather than generation speed.
- `codexTTFTSeconds` carries Codex's `time_to_first_token_ms` value. It is Codex-reported TTFT and does not claim first visible text timing.
- `streamingTPS` is always `null` until a verified generation-only source is available. Tokrate never subtracts tool duration to estimate it.
- A model is `null` when absent or when more than one model is observed during a turn. Agent sessions marked by `parent_thread_id` or `agent_path`, or a structured subagent source, are omitted to avoid silently combining subagent work; from 0.1.16 the output of spawned child sessions is counted separately as delegated output (see "Delegated output and efficiency indicator (0.1.16)").
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
| Codex | codex-rollout-v2 (v1 before 0.1.14) | turn-v1 | Existing completed-turn accounting, plus response speed |
| Claude Code | claude-transcript-v4 (v3 before 0.1.14) | claude-observed-turn-v1 | Human prompt through terminal response in the primary transcript; unique API message usage, plus response speed |
| Claude Code subagent | claude-transcript-v4 (v3 before 0.1.14) | claude-observed-subagent-turn-v1 | Subagent task prompt through its terminal response; sourceKind `subagent` |
| Grok Build | grok-session-v2 (v1 before 0.1.15) | grok-observed-work-turn-v1 | Matched completed work-turn events and usage; includes nested agent output, plus whole-turn response speed (see "Grok Build response speed (0.1.15)") |

Claude/Grok TTFT and streaming rate are null. Reasoning token details are not added to output tokens. Exclude ambiguous/incomplete windows rather than fabricate timing. Claude tool-result records are not human turn starts; deduplicate repeated content blocks by API message ID. Primary turns exclude sidechains; subagent transcripts are measured separately (0.1.12, below). Grok usage timestamps record persistence after completion: require exact session/unique turn-number joins (Grok events `turn_number` is 0-based while the usage ledger `turnNumber` is 1-based, so event turn N joins ledger turn N+1), usage time from one second before to 60 seconds after completion, and no later than the next known primary start. The 60-second cap is a conservative Tokrate bound; incomplete/colliding/ambiguous joins are excluded, repeated snapshots are deduplicated, and child sessions are not separately counted. Grok model attribution requires exactly one modelUsage entry: older missing breakdowns stay Unknown even if a selected/primary model is recorded. Grok reasoning effort comes only from the session folder's `summary.json` `reasoning_effort` (64 KiB cap; nothing else is retained, and `chat_history.jsonl` is never read). Because the user can change it between turns, a turn gets an effort only when it started while Tokrate was already watching the session and the value read at start equals the value at emission; turns read during initial catch-up or after a change stay Unknown.

Default roots are `~/.claude/projects` (or `CLAUDE_CONFIG_DIR/projects`) and `~/.grok/sessions` (or `GROK_HOME/sessions`). Only source metadata and numeric usage are retained. Raw messages, paths, session IDs, diagnostic logs and auth data are never uploaded. The same saved OFF and future-only sharing behavior applies to all tools. Unknown geography/provider/model must not be presented as a provider health signal. Rates with different metric versions cannot be ranked interchangeably.

## Software update traffic

From 0.1.10, automatic software update checks are independently configurable and on by default. Sharing OFF still blocks contribution/board requests, not update requests. Updates use a fixed platform/channel feed, no contributor key or measurements, and embedded public-key signature verification. Sparkle system-profile reporting is disabled. Installation requires user action. UI, README and website must disclose the separate switch and ordinary infrastructure network metadata. Native fixture smoke must disable all updater network activity.

## Claude Code transcript v2 and subagent turns (0.1.12; current rules are v3 below)

Claude metrics emitted by 0.1.12 carry parser `claude-transcript-v2`; earlier versions emitted `claude-transcript-v1`. Both stay displayable locally as separate cohorts. From 0.1.13 new metrics carry `claude-transcript-v3` (next section) and `SharedSample` refuses to share v1 and v2 Claude records. The primary metric version stays `claude-observed-turn-v1`. The turn rules below still apply in v3, refined by the origin and synchronisation rules.

A turn starts at a human text user record and ends at the first assistant message with `stop_reason` `end_turn` or `stop_sequence`. Output tokens are summed over unique API message IDs across the whole turn. The v2 rules are:

- **Mid-turn messages.** A human text message sent while the turn is still active continues the turn: the original start time, accumulated messages, model, effort and client version are kept, and the turn identity stays the original prompt. It continues only if its timestamp is at most 30 minutes after the latest user or assistant record already consumed in that turn (tool-result records count as activity). Otherwise the stale turn is discarded and the message starts a new turn.
- **Interruptions.** A user record whose content (a string or a text block) starts with `[Request interrupted by user` discards the in-progress turn and does not start a new one.
- **Synthetic messages.** An assistant message whose model is `<synthetic>` (client-generated placeholder or error text) invalidates the turn. When that turn reaches a terminal stop reason it emits nothing. Synthetic messages never make the model ambiguous.
- **Meta records.** User records marked `isMeta` are ignored for turn starts and interjections.

Subagent transcripts (`<session>/subagents/agent-<id>.jsonl`) are read with the same turn rules but accept records marked `isSidechain: true`, `userType: external` and a safe `agentId` instead of the primary predicate. Their `.meta.json` files are not read; the model comes from assistant records. A subagent turn runs from the task prompt (or a later follow-up prompt, which is a separate turn) to its terminal response and includes tools and waiting. Metrics use client `claude-code`, parser `claude-transcript-v2` (v3 from 0.1.13), metric `claude-observed-subagent-turn-v1`, sourceKind `subagent`, provider `unknown` (attributed from 0.1.13, see below) and no TTFT. The local digest hashes `sessionId|agentId|userTurnUUID`, so subagent identities never collide with primary turns. The UI labels this metric "Subagent turn speed": subagent task prompt to final answer, including tools and waiting.

Subagent and primary turns are separate local cohorts (metric version and source differ) and are never pooled or ranked against each other. Subagent samples are shared exactly like primary ones, through the same allowlist with `sourceKind` `subagent`. The Mac app watches primary and subagent transcript files with two independent monitors under the same root, each with the existing live-tail/archive fairness, byte budgets and 2,000-file limit, so subagent files cannot starve primary monitoring.

## Claude Code transcript v3: origin-aware prompts and mid-file start (0.1.13)

Claude metrics from 0.1.13 carry parser `claude-transcript-v3`; metric versions are unchanged and cohorts of different parser versions stay separate. The v3 tuples `(claude-code, claude-transcript-v3, claude-observed-turn-v1)` and `(…, claude-observed-subagent-turn-v1)` are the only Claude tuples that are shared. v1 and v2 tuples remain supported for local display only.

**Origin-aware prompts.** Current Claude Code writes `origin: {kind: …}` on user records. For a user record that is not a tool result and has a parseable timestamp:

- If `origin` is an object, only these kinds are prompts: `human` in a primary transcript; `human` or `coordinator` in a subagent transcript. Any other kind (for example `task-notification`, a background event delivered as a non-meta user string record) is activity only: it extends the turn's last-activity time like a tool result and never starts a turn, continues one as an interjection or discards one. An object without a `kind` is not a prompt.
- If `origin` is absent (older Claude Code versions), the v2 rules apply unchanged.
- A subagent follow-up prompt (SendMessage to a running subagent) arrives in the subagent file as a user record with `origin.kind` `coordinator` and `isMeta: true`. In subagent scope it is a prompt despite `isMeta`: it continues an active turn within 30 minutes, otherwise it starts a new turn (the v2 rules). Every other `isMeta` record stays ignored. The subagent's first task prompt has no origin and no `isMeta`.
- Interruption detection is unchanged.

**Mid-file start synchronisation.** The live reader starts at a recent tail offset, so it can see the end of a turn whose start it never saw. A Claude parser whose reader started mid-file (a recent-tail reader with offset greater than 0) begins unsynchronised: it ignores prompts, so it starts no turns, until it has seen either an assistant record with stop reason `end_turn` or `stop_sequence`, or a user prompt whose `parentUuid` key is present and JSON null (an absent key does not synchronise). From then on the normal rules apply. Archive readers and tail readers whose offset clamps to 0 read from the start and are always synchronised. The archive reader measures the turns the tail reader skipped; the existing local ID deduplication removes the overlap.

**Codex start requirement.** The Codex parser emits a turn only if that parser instance observed the turn's `task_started` event, unconditionally. A completion without an observed start emits nothing. This removes model-less Codex turns measured when the app launches in the middle of a turn, whose `turn_context` was never read.

## Claude Code provider attribution and model ids (0.1.13)

Provider is attributed from explicit evidence only and never from the model name.

Each consumed non-synthetic assistant record (primary and subagent scope) yields at most one provider from its `message.id` and top-level `requestId`:

| Evidence | Provider |
| --- | --- |
| `message.id` matches `^msg_bdrk_[A-Za-z0-9]{8,64}$` | `amazon-bedrock` |
| `message.id` matches `^msg_vrtx_[A-Za-z0-9]{8,64}$` | `google-vertex` |
| `message.id` matches `^msg_01[A-Za-z0-9]{22}$` and `requestId` matches `^req_[A-Za-z0-9]{20,40}$` | `anthropic` |
| anything else | no evidence for that record |

The turn provider is that provider when every counted assistant record in the turn produced the same evidence. If any record lacks evidence or two records differ, the provider is `unknown`. Rationale: the Anthropic API returns `msg_01…` message IDs with `req_…` request IDs, AWS documents Bedrock Claude message IDs of the form `msg_bdrk_01…`, and Google documents Vertex Claude IDs of the form `msg_vrtx_01…`.

Claude model IDs are normalised before the safe-identifier check, and the normalised value is used for the turn's model-consistency comparison:

- Bedrock `^(?:[a-z]{2,6}(?:-[a-z]+)?\.)?anthropic\.(claude-[a-z0-9.-]+?)(?:-v[0-9]+(?::[0-9]+)?)?$` yields the captured model: `us.anthropic.claude-sonnet-4-5-20250929-v1:0` becomes `claude-sonnet-4-5-20250929`, `anthropic.claude-3-haiku-20240307-v1:0` becomes `claude-3-haiku-20240307`, `global.anthropic.claude-opus-4-6-v1` becomes `claude-opus-4-6`.
- Vertex `^(claude-[a-z0-9.-]+)@([0-9]{8})$` becomes `\1-\2`: `claude-sonnet-4-5@20250929` becomes `claude-sonnet-4-5-20250929`.
- Anything else containing `:`, `/` or other unsafe characters after normalisation (for example Bedrock ARNs and application inference profiles) leaves the model unknown. `<synthetic>` handling is unchanged.

Sharing accepts the providers `openai`, `anthropic`, `xai` and `unknown` for every client, and `amazon-bedrock` and `google-vertex` only for client `claude-code`; other clients carrying them are not shared. The local cohort identity and the community board ID use the same provider allowlist.

Limitation: subagent measurement requires Claude Code versions that write `<session>/subagents/agent-*.jsonl`. Older 2.0.x layouts place `agent-*.jsonl` directly in the project folder; their subagent turns are not measured, while primary turns are.

On the Mac, the default roots can be overridden in Settings > Sources (Codex session folder, Claude Code projects folder, Grok Build sessions folder), because Finder-launched apps do not inherit `CLAUDE_CONFIG_DIR` or `GROK_HOME`. Environment variables remain the defaults when set. A chosen folder is persisted in user defaults as a path plus a security-scoped bookmark, applies only while monitoring is paused, and **Reset to default** removes it.


## Response speed (0.1.14)

Response speed (contract name `response-v1`) is the primary metric from 0.1.14. It is the output-token rate **while the model is responding**: tools and the user's own time are excluded. Turn speed stays as a secondary metric because it mostly measures workload (tool runs, automated check-ins): Sonnet subagents showed 3.6 tok/s turn speed against about 116 tok/s per response on real data. UI vocabulary: "Response speed · tok/s"; definition line "Output tokens per second while the model is responding — tools and your time excluded." Response speed is one definition across coding tools and source kinds; it never claims to be streaming speed.

### What counts as a response

A **response** is one API response. For each response:

- **start** is the timestamp of the latest record that triggered the request, **end** is the timestamp of the response's last record, and `duration = end − start`.
- It **qualifies** when its output tokens are at least 200 (`RESPONSE_MIN_OUTPUT_TOKENS`), `0 < duration ≤ 600 s`, and it is not synthetic. Output tokens include thinking/reasoning tokens, exactly as turn speed does.

Per turn three optional fields are recorded: `responseOutputTokens` (sum of the qualifying responses' output tokens), `responseDurationSeconds` (sum of their durations) and `responseCount` (how many qualified). They are all absent when no response qualified or when the source cannot provide per-response timing. Turn response speed is `responseOutputTokens / responseDurationSeconds`. Only responses that began inside the reported turn are counted; a turn that is discarded (interrupted, synthetic, unsynchronised, incomplete usage) reports no turn and therefore no response fields. Metric versions are unchanged; the emitted record carries a new measurement, so parser versions are `claude-transcript-v4` and `codex-rollout-v2` (earlier parser versions stay displayable locally; records saved before 0.1.14 decode with no response fields and Codex records without a parser version decode as `codex-rollout-v1`). Cohorts of different parser versions stay separate for turn speed; response speed merges a model across them.

### Claude Code

A response is one unique `message.id` (all records that share it). Primary and subagent transcripts use the same rules.

- **start**: the timestamp of the record whose `uuid` equals the `parentUuid` of the response's *first* assistant record, when that record was seen in this file (any type: real data shows the parent is usually an `attachment` record written just before the request, sometimes a meta or regular user record) and its timestamp is not later than the first assistant record's. Otherwise (parent missing, forgotten or later) the fallback is the timestamp of the latest user-type record before the response's first record: a human prompt, a `tool_result`, a notification or any `isMeta` record. A user record written while the response streams never moves its start. The parser remembers a bounded `uuid → timestamp` map of the last 4,096 accepted records per file, reset on file replacement. Bookkeeping `attachment` records (`deferred_tools_record`) are not request triggers; see "Measurement sanity (0.1.16)".
- **end**: the timestamp of the last assistant record with that `message.id`.
- **tokens**: the largest `message.usage.output_tokens` over the message's records (live files carry partial counts on the earlier records and the final count on the last).
- Messages with the model `<synthetic>`, a missing or unsafe `message.id`, or missing usage never qualify.

**Terminal hold.** About a third of `end_turn` messages are written thinking-first: the first record already carries `stop_reason` `end_turn` with a partial usage snapshot and the text block follows in another record with the same `message.id`. After a terminal record (`end_turn` or `stop_sequence`) the turn is therefore **pending**. Further records with the same `message.id` update its usage and end time. The turn (and its final response) closes when:

1. a record with a different `message.id`, or any user-type record, arrives; or
2. at the end of a poll in which the reader is caught up with the file, the pending message's latest content block is not `thinking`; or
3. the pending turn has waited 30 seconds (checked at the end of a poll with the injectable poll clock); or
4. the read is an archive or command-line read and the end of the file is reached.

The turn's `completedAt` is the timestamp of the terminal message's last record. A completed (stop-reason carrying) non-terminal response closes the same way (rules 1, 2, 3, 4) and is then final.

### Codex

Codex rollouts record one `token_usage_record` per API response. Its payload (`turn_id`, `response_id`, `usage`, `turn_token_usage`) has `usage`, the response's own token usage, and `turn_token_usage`, the cumulative turn total (the per-response outputs sum to the turn total). The record's own top-level `timestamp` is the response end. Per-response counts, types and timestamps were checked against real rollouts under Codex 0.159.2.

- **tokens**: `usage.output_tokens` (includes reasoning output, as the turn metric's output does). The `token_count` event's `last_token_usage` repeats the same numbers, sometimes more than once per response; it is not used.
- **start**: the timestamp of the latest *trigger* record before the response's first output item. Triggers are `event_msg` `task_started`, a `response_item` `message` with role `user`, any `response_item` whose type ends in `_output` (`function_call_output`, `custom_tool_call_output`, …) and a `response_item` `agent_message` (a message delivered from another agent). Output items are the other `response_item` types (`reasoning`, `function_call`, `custom_tool_call`, assistant `message`, …); developer messages are ignored. A trigger arriving after the first output item (before the usage record) does not move the start.
- **end**: the usage record's `timestamp`. Records are deduplicated by `response_id` within a turn. A response needs a known start (a trigger seen by this parser instance).
- The turn still completes at `task_complete` as before and must have been observed to start. Agent sessions are excluded as before.

### Grok Build

From 0.1.15 (parser `grok-session-v2`) Grok Build turns carry response speed; see "Grok Build response speed (0.1.15)" below. Records saved by earlier versions (`grok-session-v1`) have no response fields and keep displaying as turn speed only.

### Live response stream (local only)

The parsers also expose each qualifying response as it completes (model, provider, client, sourceKind, metricVersion = the turn metric version, effort, completedAt, output tokens, duration). The Mac app keeps the latest 200 in memory. They are never persisted, uploaded or shared, and carry no prompt, response, path or session identifier. They come only from live (tail) readers or archive readers, and only for responses completed after the monitor started, so replaying history never fakes a "live" value.

For the live stream responses are timed file-wide: also responses outside a human turn (for example after a notification) and in turns that are later discarded. A response is left out only for its own problems: synthetic, unsafe or missing id, missing usage, no trigger before it, tokens below 200 or a duration outside `(0, 600]`. Per-turn response fields still count only responses inside the turn.

### Menu bar, gauge and automatic model

- **Live value**: the median of the last 5 live responses of the followed model (model and provider) that completed within the last 10 minutes; "— tok/s" when there are none. The popover gauge shows the same value with the caption "last 5 responses · 2 min ago"; with no live value it shows the selected cohort's latest turn response speed and its relative time, and for a cohort without response data (for example Grok Build history recorded before 0.1.15) its latest turn speed labelled as turn speed. The delta line compares with the 24-hour median of the model's per-turn response speed. The gauge scale rule is unchanged but computed over response speeds. Accessibility label pattern: "Tokrate, Anthropic, response speed: 112.4 tokens per second".
- **Selection**: "Auto (most active)" is the default (a saved "latest" selection migrates to Auto); "Auto within a coding tool" restricts Auto to one tool; specific cohorts can still be pinned. Auto evaluates the live stream (qualifying responses only): the candidate is the model and provider with the most response output tokens in the last 10 minutes. The active model changes only when the candidate has led continuously for at least 2 minutes, or when the active model has had no qualifying response for 10 minutes. With no live responses at all it falls back to the cohort of the most recent turn with response data, else the most recent turn.
- **Provider badge** (Settings > General, default on): a small filled circle with a white letter before the number: Anthropic (`claude-` models, or provider anthropic) terracotta `#D97757` "A"; OpenAI (`gpt-*`, `o<digit>*`, `codex*`, or provider openai) green `#10A37F` "O"; xAI (`grok-*`, or provider xai) black circle with a white "X" in a light menu bar and a white circle with a black "X" in a dark one; otherwise a neutral grey dot. Letters only, no company logos.
- **Lists**: "Your models" and Compare all rank by the per-turn response speed median, grouped by model and provider across coding tools and source kinds, with turn speed as secondary text; Compare all can switch to Turn speed, which keeps the measurement groups. The trend chart defaults to response speed and can switch to turn speed (and first token when reported). The personal slower-than-usual signal and the 24-hour comparison use response speed, and fall back to turn speed for sources without response data; turn speed stays in Details. The history window adds a response-speed column (tok/s and response count).

### Sharing

`SharedSample` adds `responseOutputTokens` (Int), `responseDurationMs` (Double) and `responseCount` (Int), always encoded (null when absent) from 0.1.14. They are shared only when `1 ≤ responseOutputTokens ≤ outputTokens`, `0 < responseCount ≤ responseOutputTokens`, `responseDurationMs ≤ durationMs` and the implied speed is at most 2,000 tok/s; from 0.1.16 also `responseOutputTokens ≥ 200 × responseCount` and `responseDurationMs ≤ 600,000 × responseCount` (see "Measurement sanity (0.1.16)"); otherwise all three are null. `appVersion` is `0.1.17` (0.1.16 before).

## Grok Build response speed (0.1.15)

Grok Build records output tokens per turn, not per response, so its response speed is a whole-turn average over all model calls (short calls included). It is computed from `events.jsonl` and the `usage.json` ledger only; `updates.jsonl` and `chat_history.jsonl` are never read.

For a completed primary turn, while no nested agent frame is open:

1. A **generation window** per model call: `loop_started` opens it (closing a still-open one at that timestamp); the first following `tool_started`, or the primary `turn_ended`, closes it. Later `tool_started` events of the same call (parallel tools) and the tool and permission time that follows do nothing. Each window must satisfy `0 < duration ≤ 600 s`, otherwise the turn has no response timing.
2. Any nested `turn_started` (subagent or otherwise) inside the primary turn means the turn has no response timing: the ledger's output includes the nested output.
3. `responseCount` is the window count, which must be at least 1 and equal the ledger row's `modelCalls` when the row has one (a row without it accepts the window count; a malformed value does not).
4. `responseOutputTokens` is the turn's ledger `outputTokens` and `responseDurationSeconds` is the sum of the windows.
5. The shared response rules then apply: tokens ≥ 200 × `responseCount` (an average of at least 200 output tokens per call), tokens ≤ the turn's output tokens, duration ≤ the turn duration, and at most 2,000 tok/s. Otherwise all three fields are null.

Grok contributes no live response: a turn average is not a response, so the live readout is unchanged and the hero falls back to the latest turn's response speed. Sums of windows matched Grok's own API duration within 0.2 s on three real turns (179.9 s, 99.2 s and 41.3 s; 9, 6 and 3 model calls, equal to the ledger's `modelCalls`; 69.7, 81.0 and 68.5 tok/s). Metric version `grok-observed-work-turn-v1` and record ids are unchanged; parser version becomes `grok-session-v2`, and `grok-session-v1` stays displayable locally.

Copy. Short note (row and badge tooltips, app caption): "Grok Build: average over all model calls in a turn". Explanation (methodology, info popovers and app help): "Grok Build records output tokens per turn, not per response, so its response speed is the turn's output tokens divided by the time its model calls spent generating (tool runs and permission waits excluded). Short calls are included, which can make it read lower than per-response measurements from Codex and Claude Code. Turns with nested agents are not counted." The Mac chart shows "No response speed for these Grok Build turns: they were recorded before Tokrate 0.1.15." for Grok history that has none.

## Measurement sanity (0.1.16)

Three rules keep physically impossible numbers out of every view and upload. No parser or metric versions change.

1. **`deferred_tools_record` is not a request trigger.** Claude Code writes an `attachment` record with `attachment.type` `deferred_tools_record` when the API response *arrives*, in the same millisecond as the response's first assistant record, which names it as `parentUuid`. Taking its timestamp as the request start collapsed the response duration (336 output tokens in 0.002 s, 167,992 tok/s). When the parser remembers its `uuid → timestamp` map, such a record is remembered under its own parent's timestamp (so chains resolve to the first real trigger) and not at all when the parent is unknown, which falls back to the latest user-type record. Primary and subagent transcripts, per-turn response fields and the live response stream all share this rule. On real transcripts 847 of 6,916 responses had such a parent and 401 of 2,103 qualifying responses (19%) were inflated: their median read 284 tok/s instead of 90 tok/s, with a maximum of 572,973; after the fix the maximum over all real transcripts is 206 tok/s.
2. **2,000 tok/s is a measurement bound.** A response qualifies only when `outputTokens / duration ≤ 2,000` (`ResponseSpeed.maximumTokensPerSecond`), for Claude Code and Codex per-turn sums and the live stream alike. A turn whose whole-turn throughput exceeds 2,000 tok/s is a measurement error: Codex, Claude Code (primary and subagent) and Grok Build emit no record for it, like any other invalid duration. Grok's response rule 5 uses the same constant. History saved by earlier builds is cleaned when it loads: such turns are dropped.
3. **One response-validity rule.** The three response fields are valid only when `1 ≤ responseCount`, `responseOutputTokens ≥ 200 × responseCount`, `responseOutputTokens ≤ outputTokens`, `0 < responseDurationSeconds ≤ 600 × responseCount`, `responseDurationSeconds ≤ durationSeconds` and the implied speed is at most 2,000 tok/s. Sharing and history loading both use it (`TurnMetric.hasPlausibleResponseTiming`): an upload carries null response fields for a failing turn, and loading history sets all three fields to nil on a failing record. A turn above the 2,000 tok/s bound is not shared at all, because the server would reject the whole batch.

## Provider region and consent notice 2 (0.1.14)

- **providerRegion.** For Claude models routed through Amazon Bedrock the inference-profile region prefix that model normalisation strips (`us`, `eu`, `apac`, `global`, `jp`, `au`, `ca`, `us-gov`) is kept as the new `TurnMetric.providerRegion`: that value, or `unknown` when the ID has no prefix, an unrecognised prefix, or the turn's messages disagree. It is nil for every other provider. It is part of the local cohort identity and is shared as `providerRegion` (always encoded for 0.1.14, null unless the provider is `amazon-bedrock`). It is not part of the public board's cohort ID.
- **Region derivation.** From 0.1.14 the server derives the contributor's continent from the connection's country at upload time (via Cloudflare). Only the continent is stored: the country and IP address are not. Regions are shown publicly only with at least 3 contributors. The app sends no location field.
- **Consent notice version 2.** The sharing consent notice version is 2 and mentions the region derivation and the response-speed fields. A saved consent for notice version 1 with sharing on is treated like a legacy default-on setting: sharing is paused, with no identity access and no community requests, and the consent choice is shown again until the user chooses. A saved OFF stays OFF.

## Delegated output and efficiency indicator (0.1.16)

Tokrate gets a third metric next to response speed and turn speed: the **Efficiency indicator**. It is a heuristic *indicator*, not a benchmark, and is labelled that way everywhere. It asks how many output tokens a model spends to finish one request compared with a typical request; higher means fewer tokens. No parser or metric versions change, and turn speed and response speed are unchanged. The new per-turn field is gated by app version 0.1.16.

### `delegatedOutputTokens`

An optional non-negative integer in local history, the UI snapshot and uploads: the output tokens of delegated subagent work started during this primary turn that are not already part of `outputTokens`. `nil`/`null` means the attribution is not final yet, or does not apply (subagent records, history saved before 0.1.16).

| Source | Value |
| --- | --- |
| Grok Build primary turns | `0` at emission. Grok's ledger `outputTokens` already includes nested agent output, so these turns are final immediately. |
| Claude Code primary turns | The sum of the output tokens of the Claude subagent turns attributed to the turn. |
| Codex primary turns | The sum of the output tokens of the spawned child-session turns attributed to the turn. |
| Claude Code subagent records (`sourceKind` `subagent`) | Always `nil`. They are recorded, shown and shared exactly as before. |

### Delegated work sources

A delegated work item is one subagent or child turn; parsers report its lifecycle (`started`, `finished` with output tokens, `discarded`) through a side channel beside the live-response one. Work items exist in memory only.

- **Claude Code.** Subagent transcripts `<project>/<sessionId>/subagents/agent-<agentId>.jsonl` carry the parent's `sessionId`. Each subagent turn, from task prompt to terminal response, is one work item: root session `sessionId`, work id the turn's existing identity digest, start the turn start, finish its `completedAt`, tokens the turn's `outputTokens`. An interrupted or stale subagent turn is a discarded item.
- **Codex.** Child sessions whose first-line `session_meta.payload.source` is `{ "subagent": { "thread_spawn": { … } } }` are delegated work. From 0.1.16 they are read fully from their first line (the live tail shortcut and the archive pass do not apply), only to produce work items: they still emit no `TurnMetric` and no live response sample. Root session is `payload.session_id` when present (the children's `session_id` is the root thread id), else `payload.parent_thread_id`; a child of a child therefore attributes to the root. Each child turn (`task_started` to `task_complete`) is one item with the turn's final `turn_token_usage.output_tokens`. Aborted (`turn_aborted`) or incomplete turns are discarded. Every other subagent kind stays fully skipped: `source.subagent.other` (for example `"guardian"` approval reviews, which are harness overhead rather than the model's choice) and structured sources without `thread_spawn`. Primary Codex sessions use `payload.session_id`, else `payload.id`, as their root (equal for primary sessions).
- **Grok Build.** No work items: nested output is already in `outputTokens`.

### Attribution (in memory only)

Root-session identifiers are kept in memory only, as a SHA-256 digest of `client|rawRootSessionId`; they are never written to disk or uploaded, and nothing identifier-bearing is logged. The monitor that owns both the primary and the delegated source attributes: `ClaudeSessionMonitor` (its primary and subagent monitors) and `CodexSessionMonitor`.

A work item W belongs to primary turn T when W's root session equals T's and `T.startedAt ≤ W.startedAt ≤ T.completedAt`, where `T.startedAt = completedAt − durationSeconds`.

A primary turn is emitted immediately as before, with `delegatedOutputTokens = nil`, so speeds update without delay, and the monitor keeps a pending entry for it. On every poll a pending entry becomes **final** when all of these hold:

1. `now ≥ completedAt + 30 s` (`DELEGATION_SETTLE_SECONDS`);
2. no delegated-source file that could still hold unread work items started inside T's window is behind (turn-scoped backlog, below);
3. no *open* work item (started, neither finished nor discarded) of the root session started inside T's window, or `now ≥ completedAt + 30 min` (`DELEGATION_MAX_WAIT_SECONDS`), in which case open items are ignored.

**Turn-scoped backlog (0.1.17).** Until 0.1.16 condition 2 waited for the delegated source to have no historical backlog at all. Because every launch re-reads seven days of files (gigabytes of Codex sessions at about 1 MiB per 2 s poll), every turn stayed `nil`, and unshared, for about an hour after each launch, however recent it was. Condition 2 is now evaluated per pending turn T with start `S = completedAt − durationSeconds`. A work item's start record is written at or after S, so a delegated-source file last modified before `S − 2 s` (the tolerance covers timestamp precision) cannot hold one and never blocks T. Every other file blocks T only when:

- **live part:** its live reader is not caught up, or the file has a modification the live reader has not read (`modifiedAt > liveServicedModification`), and `modifiedAt ≥ S − 2 s`;
- **archive part:** its archive reader (which only covers the content before the live tail's start offset) is not done, `modifiedAt ≥ S − 2 s`, and `liveStartedAt ≥ S − 2 s`, where `liveStartedAt` is the wall-clock `now` of the poll that created and positioned the live reader (a live reader not positioned yet counts as positioned after S). Records at or after S can only sit in the archive part when the live tail was positioned after S. Codex delegated child files are read from their header line by the live reader and have no archive part;
- a file discovered but not yet given a live reader blocks T when `modifiedAt ≥ S − 2 s`.

For Claude Code only the subagent monitor's files count, and a failed subagent poll keeps every pending turn blocked. For Codex the monitor's own files count. The monitor exposes the predicate (`hasBacklog(affectingWorkStartedAt:)` / `has_delegation_backlog_since(S)`) over a per-file snapshot `(modifiedAt, livePending, archivePending, liveStartedAt)`; the attributor evaluates it for each pending entry with that entry's start. A turn finished after launch is therefore final about 30 s after completion, once its own session's files are caught up, while older history is still replayed; historical turns finalize progressively as the replay passes their period. Conditions 1 and 3, the caps and the upload fields are unchanged (notice version stays 3; no parser or metric version change).

On finalization the monitor re-emits the same record id with `delegatedOutputTokens = Σ finished W.outputTokens` (0 when none); the store's upsert by id replaces the stored record, and a settled total is never replaced by a pending re-emission of a replay. Memory is bounded: work items older than the 7-day history retention are dropped, pending entries are dropped when final, and hard caps of 20,000 work items and 10,000 pending entries discard the oldest. Every launch re-parses seven days of files, so history is re-attributed after an upgrade; records that never finalize keep `nil` and are excluded from the indicator.

### Sharing and consent notice 3

- `SharedSample` gains `delegatedOutputTokens`, always encoded (explicit `null` when nil). It is shared only when `0 ≤ delegatedOutputTokens ≤ 100,000,000`; a primary turn outside that range, or without a total, builds no sample. Subagent records always share `null`. `appVersion` is `0.1.17` (0.1.16 before).
- **Primary turns are enqueued for sharing only once final** (`delegatedOutputTokens != nil`). Subagent records are enqueued as before. The existing rules still apply: future-only `completedAt ≥ consentStartedAt`, the seen-id dedupe and the queue caps. The old "only ids not yet in history" pre-filter is replaced by this readiness rule so the settled re-emission is shared, and each record is shared at most once.
- **Consent notice version 3.** `SharingPreferences.currentNoticeVersion` is 3 (desktop: `SHARING_NOTICE_VERSION = "2026-10-05-v3"`). Re-consent behaves as for version 2: a saved OFF stays OFF. The notice adds: "From 0.1.16 each turn also includes the output tokens of subagent work it started (delegated output tokens), used for the efficiency indicator." The consent example payload includes the new key.
- **Server rule.** Before 0.1.16 the key is forbidden; from 0.1.16 it is required. For `sourceKind` `primary` it is a non-negative integer ≤ 100,000,000; for `subagent` it is `null`.

### Efficiency indicator definition (`efficiency-v1`)

- **Total tokens of a turn** = `outputTokens + delegatedOutputTokens`. Output includes reasoning tokens in all three tools.
- **Eligible turn:** `sourceKind` `primary`, known model, supported source tuple, `delegatedOutputTokens != nil`, and total ≥ 200 (`EFFICIENCY_MIN_TOTAL_TOKENS`, the response-speed floor; it drops trivial and automated turns).
- **Group (row)** = model + reasoning effort (missing effort is `unknown`), combined across coding tools, providers, client versions and parser versions.
- **Reference median R** = median total tokens over all eligible turns in the same window (all models). **Group median M** = median total tokens over the group's eligible turns. **Indicator** = `round(100 × R / M)`: 100 is typical, 200 means half the tokens, 50 twice the tokens.
- **Local (Mac and desktop apps).** The window is the whole local history (last 7 days), independent of the 24 h / 7 d chart toggle. A group gets an indicator only with ≥ 20 eligible turns (`EFFICIENCY_MIN_TURNS`); below that the app shows "n of 20 requests" and no value. R needs ≥ 20 eligible turns overall, else there are no indicators.
- **Local trend chart.** Per bucket of the selected range, indicator = `round(100 × R / median(bucket totals))` for the selected group, using the same 7-day R; a bucket needs ≥ 3 eligible turns, else it is a gap. With "all models" selected the chart shows the reference itself, median total tokens per request (unit "tokens/request").
- **Details per group:** eligible turns, median total tokens, p25 and p75 total tokens, median reasoning share (`reasoningOutputTokens / outputTokens` where known, "—" otherwise) and delegated share (Σ delegated / Σ total).
- **Community (tokrate.dev).** Same definition per board window with contributor weighting: group median = median of per-contributor medians, R = median of per-contributor medians over all eligible turns. Floors: normal ≥ 10 contributors and ≥ 50 eligible turns per group; Early data mode ≥ 1 contributor and ≥ 20 eligible turns; R needs the same floors over all eligible turns. p25/p75 and reasoning share are pooled over turns (detail only); delegated share is Σ delegated / Σ total. History points use the window's R and the bucket's group median and need ≥ 3 eligible turns, else `null`.

Copy. Definition: "Fewer output tokens per request scores higher. 100 = a typical request." The metric is **Efficiency indicator** (short label **Efficiency**), always shown with an "Indicator" badge or label, as a unitless integer without "%" or "tok/s", as a bar relative to the row maximum with a thin tick at 100 labelled "typical" where space allows. Empty state: "Not enough requests yet: the efficiency indicator needs 20 eligible requests per model."

### Methodology note

- Subagent work is counted for the request that started it.
- Background subagents still running 30 minutes after the request ends are not counted.
- Codex approval-review ("guardian") sessions are not counted.
- Requires Tokrate 0.1.16 or newer.
