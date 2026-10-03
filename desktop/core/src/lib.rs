//! Portable, content-free metrics processing shared by the Tokrate desktop hosts.

mod history;
mod model;
mod monitor;
mod parser;
mod reader;
mod sharing;

#[cfg(test)]
mod tests;

pub use history::History;
pub use model::{ReportedReasoningEffort, TurnMetric};
pub use monitor::Monitor;
pub use sharing::{
    signed_request, SharedSample, SharedSampleEnvelope, SharingQueue, SignedRequest, APP_VERSION,
    MAX_PENDING_SAMPLES,
};

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
