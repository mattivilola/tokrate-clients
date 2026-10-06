//! Portable, content-free metrics processing shared by the Tokrate desktop hosts.

mod claude_parser;
mod delegation;
mod grok;
mod history;
mod live;
mod model;
mod monitor;
mod parser;
mod reader;
mod selector;
mod sharing;
mod sources;

#[cfg(test)]
mod tests;

pub use grok::GrokMonitor;
pub use history::History;
pub use live::{
    LiveResponses, LiveScope, LiveValue, LIVE_CAPACITY, LIVE_VALUE_COUNT, LIVE_VALUE_WINDOW_MINUTES,
};
pub use model::{
    response_qualifies, ProviderBadge, ReportedReasoningEffort, ResponseMetric, ToolSurface,
    TurnMetric, CLAUDE_CLIENT, CLAUDE_METRIC_VERSION, CLAUDE_PARSER_VERSION,
    CLAUDE_SUBAGENT_METRIC_VERSION, CODEX_CLIENT, CODEX_METRIC_VERSION, CODEX_PARSER_VERSION,
    GROK_CLIENT, GROK_METRIC_VERSION, GROK_PARSER_VERSION, RESPONSE_MAX_DURATION_SECONDS,
    RESPONSE_METRIC_VERSION, RESPONSE_MIN_OUTPUT_TOKENS,
};
pub use monitor::Monitor;
pub use selector::{
    fallback_model, AutoSelector, ModelKey, SelectionMode, AUTO_LEAD_MINUTES, AUTO_QUIET_MINUTES,
    AUTO_WINDOW_MINUTES,
};
pub use sharing::{
    signed_request, SharedSample, SharedSampleEnvelope, SharingQueue, SignedRequest, APP_VERSION,
    MAX_PENDING_SAMPLES,
};
pub use sources::SourceMonitor;

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
