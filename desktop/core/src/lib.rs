//! Portable, content-free metrics processing shared by the Tokrate desktop hosts.

mod antigravity;
mod antigravity_db;
mod antigravity_turns;
mod claude_parser;
mod delegation;
mod grok;
mod history;
mod live;
mod model;
mod monitor;
mod opencode;
mod opencode_db;
mod opencode_turns;
mod parser;
mod protobuf;
mod reader;
mod selector;
mod sharing;
mod sources;
mod sqlite_read;

#[cfg(test)]
mod antigravity_tests;
#[cfg(test)]
mod opencode_tests;
#[cfg(test)]
mod tests;

pub use antigravity::AntigravityMonitor;
pub use grok::GrokMonitor;
pub use history::History;
pub use live::{
    LiveResponses, LiveScope, LiveValue, LIVE_CAPACITY, LIVE_VALUE_COUNT, LIVE_VALUE_WINDOW_MINUTES,
};
pub use model::{
    response_qualifies, ProviderBadge, ReportedReasoningEffort, ResponseMetric, ToolSurface,
    TurnMetric, ANTIGRAVITY_CLIENT, ANTIGRAVITY_METRIC_VERSION, ANTIGRAVITY_PARSER_VERSION,
    CLAUDE_CLIENT, CLAUDE_METRIC_VERSION, CLAUDE_PARSER_VERSION, CLAUDE_SUBAGENT_METRIC_VERSION,
    CODEX_CLIENT, CODEX_METRIC_VERSION, CODEX_PARSER_VERSION, GROK_CLIENT, GROK_METRIC_VERSION,
    GROK_PARSER_VERSION, OPENCODE_CLIENT, OPENCODE_METRIC_VERSION, OPENCODE_PARSER_VERSION,
    RESPONSE_MAX_DURATION_SECONDS, RESPONSE_METRIC_VERSION, RESPONSE_MIN_OUTPUT_TOKENS,
};
pub use monitor::{Monitor, SourceChange, SourceFileCheckpoint};
pub use opencode::OpenCodeMonitor;
pub use selector::{
    fallback_model, tray_reading, AutoSelector, ModelKey, SelectionMode, TrayReading,
    TrayReadingKind, AUTO_LEAD_SECONDS, AUTO_WINDOW_MINUTES,
};
pub use sharing::{
    example_request_json, signed_request, SharedSample, SharedSampleEnvelope, SharingQueue,
    SignedRequest, APP_VERSION, MAX_PENDING_SAMPLES,
};
pub use sources::{SourceCheckpoints, SourceMonitor, WatchFolder};

/// Errors produced while validating or encoding a public sharing request.
#[derive(Debug)]
pub enum CoreError {
    Io(std::io::Error),
    Json(serde_json::Error),
    InvalidRequest(&'static str),
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(error) => write!(f, "I/O error: {error}"),
            Self::Json(error) => write!(f, "JSON error: {error}"),
            Self::InvalidRequest(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for CoreError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Json(error) => Some(error),
            Self::InvalidRequest(_) => None,
        }
    }
}

impl From<std::io::Error> for CoreError {
    fn from(value: std::io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<serde_json::Error> for CoreError {
    fn from(value: serde_json::Error) -> Self {
        Self::Json(value)
    }
}
