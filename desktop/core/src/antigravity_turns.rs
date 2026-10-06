//! Turns and live responses of one Antigravity conversation, built from a database snapshot.

use crate::antigravity_db::{Executor, Generation, Snapshot, Step};
use crate::model::{
    response_qualifies, speed_is_plausible, ResponseMetric, ResponseTotals, ToolSurface,
    TurnMetric, ANTIGRAVITY_CLIENT, ANTIGRAVITY_METRIC_VERSION, ANTIGRAVITY_PARSER_VERSION,
};
use chrono::{DateTime, Utc};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

/// The execution state Antigravity writes for a finished run.
const FINISHED_STATE: u64 = 4;
const EFFORTS: [&str; 6] = ["minimal", "low", "medium", "high", "xhigh", "max"];
const MAX_IDENTIFIER_BYTES: usize = 80;

/// One finished execution, ready to emit once.
pub(crate) struct ExecutionTurn {
    pub execution_id: String,
    pub metric: TurnMetric,
}

/// A qualifying model call, ready to publish once.
pub(crate) struct LiveCall {
    pub step_index: i64,
    pub response: ResponseMetric,
}

/// Executions of the snapshot that are finished and measurable. An execution id that appears in
/// more than one executor row is ambiguous and skipped.
pub(crate) fn finished_turns(
    conversation_id: &str,
    surface: ToolSurface,
    snapshot: &Snapshot,
) -> Vec<ExecutionTurn> {
    let executors = unique_executors(snapshot);
    let mut steps: HashMap<&str, Vec<&Step>> = HashMap::new();
    for step in &snapshot.steps {
        if let Some(id) = step.execution_id.as_deref() {
            steps.entry(id).or_default().push(step);
        }
    }
    let mut turns = Vec::new();
    for executor in snapshot.executors.iter() {
        if executor.state != FINISHED_STATE || !executors.contains_key(executor.id.as_str()) {
            continue;
        }
        let Some(execution_steps) = steps.get(executor.id.as_str()) else {
            continue;
        };
        if let Some(metric) = execution_metric(
            conversation_id,
            surface,
            executor,
            execution_steps,
            snapshot,
        ) {
            turns.push(ExecutionTurn {
                execution_id: executor.id.clone(),
                metric,
            });
        }
    }
    turns
}

fn execution_metric(
    conversation_id: &str,
    surface: ToolSurface,
    executor: &Executor,
    steps: &[&Step],
    snapshot: &Snapshot,
) -> Option<TurnMetric> {
    let calls: Vec<&Step> = steps
        .iter()
        .copied()
        .filter(|step| step.usage.is_some())
        .collect();
    if calls.is_empty() {
        return None;
    }
    let mut spans = Vec::with_capacity(calls.len());
    for call in &calls {
        let (created, completed) = (call.created?, call.completed?);
        if completed < created {
            return None;
        }
        spans.push((created, completed));
    }
    let started_at = steps.iter().filter_map(|step| step.created).min()?;
    let completed_at = steps
        .iter()
        .filter_map(|step| step.completed.or(step.created))
        .max()?;
    let duration = seconds_between(started_at, completed_at)?;
    let usages = calls.iter().filter_map(|call| call.usage);
    let output_tokens = usages
        .clone()
        .fold(0i64, |sum, usage| sum.saturating_add(usage.output_tokens));
    let reasoning_tokens = usages
        .clone()
        .fold(0i64, |sum, usage| sum.saturating_add(usage.thinking_tokens));
    // 9.2 counts the uncached input and 9.5 the cache reads; the turn's input includes both.
    // Proto3 omits a zero, so an absent count is 0, not missing.
    let cache_read_tokens = usages.clone().fold(0i64, |sum, usage| {
        sum.saturating_add(usage.cache_read_tokens)
    });
    let input_tokens = usages.fold(cache_read_tokens, |sum, usage| {
        sum.saturating_add(usage.input_tokens)
    });
    if duration <= 0.0 || !speed_is_plausible(output_tokens, duration) {
        return None;
    }

    let generations: Vec<Option<&Generation>> = calls
        .iter()
        .map(|call| snapshot.generations.get(&call.generation))
        .collect();
    let model = common_model(&generations);
    let provider = provider_of(model.as_deref(), &generations);
    let effort = effort_of(executor.variant.as_deref(), model.as_deref());

    let mut responses = ResponseTotals::default();
    for (call, (created, completed)) in calls.iter().zip(&spans) {
        let tokens = call.usage.map_or(0, |usage| usage.output_tokens);
        if let Some(seconds) = seconds_between(*created, *completed) {
            if response_qualifies(tokens, seconds) {
                responses.add(tokens, seconds);
            }
        }
    }
    let (response_output_tokens, response_duration_seconds, response_count) = responses.fields();

    let mut metric = TurnMetric::new_observed(
        turn_id(conversation_id, &executor.id),
        completed_at,
        model,
        output_tokens,
        duration,
        None,
        Some(reasoning_tokens),
        Some("primary".to_owned()),
        Some(provider.to_owned()),
        effort,
        ANTIGRAVITY_CLIENT,
        ANTIGRAVITY_PARSER_VERSION,
        ANTIGRAVITY_METRIC_VERSION,
    );
    metric.response_output_tokens = response_output_tokens;
    metric.response_duration_seconds = response_duration_seconds;
    metric.response_count = response_count;
    // Cache writes are not recorded.
    metric.set_prompt_cache(Some(input_tokens), Some(cache_read_tokens), None);
    metric.surface = Some(surface);
    // Subagent work started by the execution is not part of its output and cannot be attributed
    // yet: the turn stays local and is never final.
    metric.delegated_output_tokens = if steps.iter().any(|step| step.has_subtrajectory) {
        None
    } else {
        Some(0)
    };
    Some(metric)
}

/// Model calls that completed after `since` and qualify as a response, oldest first. The caller
/// publishes each step index once.
pub(crate) fn live_calls(
    conversation_id: &str,
    snapshot: &Snapshot,
    since: DateTime<Utc>,
) -> Vec<LiveCall> {
    let executors = unique_executors(snapshot);
    let mut calls = Vec::new();
    for step in &snapshot.steps {
        let (Some(usage), Some(created), Some(completed)) =
            (step.usage, step.created, step.completed)
        else {
            continue;
        };
        if completed <= since || completed < created {
            continue;
        }
        let Some(seconds) = seconds_between(created, completed) else {
            continue;
        };
        if !response_qualifies(usage.output_tokens, seconds) {
            continue;
        }
        let generation = snapshot.generations.get(&step.generation);
        let Some(model) = generation.and_then(|generation| safe_model(generation.model.as_deref()))
        else {
            continue;
        };
        let variant = step
            .execution_id
            .as_deref()
            .and_then(|id| executors.get(id))
            .and_then(|executor| executor.variant.as_deref());
        calls.push(LiveCall {
            step_index: step.idx,
            response: ResponseMetric {
                id: response_id(conversation_id, step.idx),
                completed_at: completed,
                provider: Some(provider_of(Some(&model), &[generation]).to_owned()),
                reasoning_effort: effort_of(variant, Some(&model)),
                model: Some(model),
                client: ANTIGRAVITY_CLIENT.to_owned(),
                source_kind: Some("primary".to_owned()),
                metric_version: ANTIGRAVITY_METRIC_VERSION.to_owned(),
                output_tokens: usage.output_tokens,
                duration_seconds: seconds,
            },
        });
    }
    calls.sort_by(|left, right| {
        left.response
            .completed_at
            .cmp(&right.response.completed_at)
            .then_with(|| left.step_index.cmp(&right.step_index))
    });
    calls
}

fn unique_executors(snapshot: &Snapshot) -> HashMap<&str, &Executor> {
    let mut counts: HashMap<&str, (usize, &Executor)> = HashMap::new();
    for executor in &snapshot.executors {
        counts
            .entry(executor.id.as_str())
            .or_insert((0, executor))
            .0 += 1;
    }
    counts
        .into_iter()
        .filter(|(_, (count, _))| *count == 1)
        .map(|(id, (_, executor))| (id, executor))
        .collect()
}

fn safe_model(model: Option<&str>) -> Option<String> {
    model
        .filter(|value| {
            !value.is_empty()
                && value.len() <= MAX_IDENTIFIER_BYTES
                && value.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b'+')
                })
        })
        .map(str::to_owned)
}

/// The model every call agrees on; nil when any call has none or they differ.
fn common_model(generations: &[Option<&Generation>]) -> Option<String> {
    let mut models = generations.iter().map(|generation| {
        generation.and_then(|generation| safe_model(generation.model.as_deref()))
    });
    let first = models.next()??;
    models
        .all(|model| model.as_deref() == Some(first.as_str()))
        .then_some(first)
}

/// `google` for a Gemini model whose every generation says it used no non-Gemini model.
fn provider_of(model: Option<&str>, generations: &[Option<&Generation>]) -> &'static str {
    let gemini = model.is_some_and(|model| model.starts_with("gemini-"))
        && !generations.is_empty()
        && generations
            .iter()
            .all(|generation| generation.is_some_and(|generation| generation.gemini_only));
    if gemini {
        "google"
    } else {
        "unknown"
    }
}

/// The variant id is the model id plus `-<effort>`; anything else leaves the effort unknown.
fn effort_of(variant: Option<&str>, model: Option<&str>) -> Option<String> {
    let suffix = variant?.strip_prefix(model?)?.strip_prefix('-')?;
    EFFORTS.contains(&suffix).then(|| suffix.to_owned())
}

fn seconds_between(start: DateTime<Utc>, end: DateTime<Utc>) -> Option<f64> {
    Some((end - start).num_nanoseconds()? as f64 / 1e9)
}

fn digest(parts: &[&str]) -> String {
    format!("{:x}", Sha256::digest(parts.join("|").as_bytes()))
}

/// SHA-256 hex of `antigravity|<conversationId>|<executionId>`.
pub(crate) fn turn_id(conversation_id: &str, execution_id: &str) -> String {
    digest(&[ANTIGRAVITY_CLIENT, conversation_id, execution_id])
}

/// Local digest only used to deduplicate live responses.
fn response_id(conversation_id: &str, step_index: i64) -> String {
    digest(&[
        ANTIGRAVITY_CLIENT,
        conversation_id,
        "response",
        &step_index.to_string(),
    ])
}
