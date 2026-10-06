use crate::claude_parser::ClaudeTranscriptParser;
use crate::delegation::{extend_bounded, DelegationEvent};
use crate::model::{ResponseMetric, TurnMetric};
use crate::parser::{CodexEventParser, JsonlEventParser};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::fs::{self, File, Metadata};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::PathBuf;

pub(crate) const MAX_LINE_BYTES: usize = 1_048_576;
const DEFAULT_TAIL_BYTES: u64 = 262_144;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub(crate) struct FileIdentity(String);

pub(crate) fn file_identity(metadata: &Metadata) -> Option<FileIdentity> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        return Some(FileIdentity(format!(
            "{}:{}",
            metadata.dev(),
            metadata.ino()
        )));
    }
    #[cfg(not(unix))]
    {
        metadata
            .created()
            .ok()
            .map(|created| FileIdentity(format!("{created:?}")))
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum Startup {
    Beginning,
    Header,
    Alignment,
    Unavailable,
    Ready,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum TailHeader {
    CodexSessionMeta,
    AnyTypedEvent,
}

/// An incremental reader with independent recent-tail and full-replay parser cursors.
pub(crate) struct IncrementalReader {
    path: PathBuf,
    offset: u64,
    pending: Vec<u8>,
    identity: Option<FileIdentity>,
    parser: Box<dyn JsonlEventParser>,
    tail_header: TailHeader,
    startup: Startup,
    dropping_oversized_line: bool,
    bytes_read_last_poll: usize,
    is_caught_up: bool,
    tail_bytes: Option<u64>,
    /// Where a previous run read this file to. Until the file grows past it the reader reads
    /// nothing; then it recovers the header and continues from here instead of from a recent tail.
    resume_at: Option<u64>,
    /// Recent-tail readers keep the responses they complete; replay readers discard them.
    collect_responses: bool,
    responses: Vec<ResponseMetric>,
    /// Every reader (tail and replay) reports delegation events; the monitor deduplicates.
    delegation_events: Vec<DelegationEvent>,
}

impl IncrementalReader {
    pub fn beginning(path: PathBuf) -> Self {
        Self::new(
            path,
            Startup::Beginning,
            None,
            Box::new(CodexEventParser::new(String::new())),
            TailHeader::CodexSessionMeta,
        )
    }

    pub fn beginning_claude(path: PathBuf) -> Self {
        let parser = ClaudeTranscriptParser::for_path(&path);
        Self::new(
            path,
            Startup::Beginning,
            None,
            Box::new(parser),
            TailHeader::AnyTypedEvent,
        )
    }

    pub fn recent_tail(path: PathBuf) -> Self {
        Self::new(
            path,
            Startup::Header,
            Some(DEFAULT_TAIL_BYTES),
            Box::new(CodexEventParser::new(String::new())),
            TailHeader::CodexSessionMeta,
        )
    }

    pub fn recent_tail_claude(path: PathBuf) -> Self {
        let parser = ClaudeTranscriptParser::for_path(&path);
        Self::new(
            path,
            Startup::Header,
            Some(DEFAULT_TAIL_BYTES),
            Box::new(parser),
            TailHeader::AnyTypedEvent,
        )
    }

    /// A live reader for a file a previous run consumed up to `offset` (a line boundary): it reads
    /// nothing until the file grows, then recovers the header and context as a recent tail does and
    /// continues from `offset`. A file that shrank or was replaced is read as a fresh recent tail.
    pub fn resumed(path: PathBuf, offset: u64) -> Self {
        Self::resume(Self::recent_tail(path), offset)
    }

    pub fn resumed_claude(path: PathBuf, offset: u64) -> Self {
        Self::resume(Self::recent_tail_claude(path), offset)
    }

    fn resume(mut reader: Self, offset: u64) -> Self {
        reader.resume_at = Some(offset);
        reader.is_caught_up = true;
        reader
    }

    fn new(
        path: PathBuf,
        startup: Startup,
        tail_bytes: Option<u64>,
        mut parser: Box<dyn JsonlEventParser>,
        tail_header: TailHeader,
    ) -> Self {
        let identity = fs::metadata(&path)
            .ok()
            .and_then(|metadata| file_identity(&metadata));
        let source_identity = path.to_string_lossy().into_owned();
        parser.reset(source_identity);
        Self {
            path,
            offset: 0,
            pending: Vec::new(),
            identity,
            parser,
            tail_header,
            startup,
            dropping_oversized_line: false,
            bytes_read_last_poll: 0,
            is_caught_up: false,
            tail_bytes,
            resume_at: None,
            collect_responses: tail_bytes.is_some(),
            responses: Vec::new(),
            delegation_events: Vec::new(),
        }
    }

    /// Delegation events this reader produced since the last call.
    pub fn take_delegation_events(&mut self) -> Vec<DelegationEvent> {
        std::mem::take(&mut self.delegation_events)
    }

    /// Responses completed by this reader since the last call. Only the recent-tail (live)
    /// reader returns any, so history replay never reaches the live stream.
    pub fn take_responses(&mut self) -> Vec<ResponseMetric> {
        std::mem::take(&mut self.responses)
    }

    /// Reads up to `max_bytes`. Once the file is read to its end, work that only waited for more
    /// records is closed using `now`.
    pub fn poll(&mut self, max_bytes: usize, now: DateTime<Utc>) -> io::Result<Vec<TurnMetric>> {
        let mut records = self.poll_records(max_bytes)?;
        if self.is_caught_up {
            // Replay readers see a whole file, so nothing more is coming for their pending turns.
            let final_read = self.tail_bytes.is_none();
            records.extend(self.parser.flush_pending(now, final_read));
        }
        self.collect_parser_output();
        Ok(records)
    }

    fn poll_records(&mut self, max_bytes: usize) -> io::Result<Vec<TurnMetric>> {
        self.bytes_read_last_poll = 0;
        if max_bytes == 0 {
            return Ok(Vec::new());
        }
        // Query size and identity from an open handle. Windows path metadata can lag an
        // append while another process still has the JSONL writer open.
        let metadata = File::open(&self.path)?.metadata()?;
        let current_size = metadata.len();
        let current_identity = file_identity(&metadata);
        if current_size < self.resume_at.unwrap_or(self.offset)
            || (self.identity.is_some()
                && current_identity.is_some()
                && self.identity != current_identity)
        {
            self.reset_for_current_file(current_identity.clone());
        }
        self.identity = current_identity;

        if self.parser.excludes_session() {
            self.offset = current_size;
            self.is_caught_up = true;
            return Ok(Vec::new());
        }
        if self.startup == Startup::Unavailable {
            self.is_caught_up = true;
            return Ok(Vec::new());
        }
        if current_size <= self.resume_at.unwrap_or(self.offset) {
            self.is_caught_up = self.resume_at.is_some()
                || self.startup == Startup::Ready
                || self.startup == Startup::Beginning;
            return Ok(Vec::new());
        }
        if self.startup == Startup::Header {
            self.is_caught_up = false;
            self.prepare_recent_tail(current_size, max_bytes)?;
            return Ok(Vec::new());
        }

        let mut read_budget = max_bytes;
        if self.startup == Startup::Alignment {
            let mut file = File::open(&self.path)?;
            file.seek(SeekFrom::Start(self.offset.saturating_sub(1)))?;
            let mut previous = [0_u8; 1];
            let count = file.read(&mut previous)?;
            self.bytes_read_last_poll += count;
            read_budget = read_budget.saturating_sub(count);
            self.dropping_oversized_line = count == 1 && previous[0] != b'\n';
            self.startup = Startup::Ready;
        }
        if read_budget == 0 {
            return Ok(Vec::new());
        }

        let count = usize::try_from((current_size - self.offset).min(read_budget as u64))
            .unwrap_or(read_budget);
        let bytes = self.read_at(self.offset, count)?;
        self.offset += bytes.len() as u64;
        self.bytes_read_last_poll += bytes.len();
        self.is_caught_up = self.offset >= current_size;
        if bytes.is_empty() {
            return Ok(Vec::new());
        }
        self.pending.extend_from_slice(&bytes);
        Ok(self.consume_complete_lines())
    }

    fn prepare_recent_tail(&mut self, current_size: u64, max_bytes: usize) -> io::Result<()> {
        if self.tail_header == TailHeader::AnyTypedEvent {
            if let Some(resume_at) = self.resume_at.take() {
                // Claude records carry their own context, and a parser that has seen nothing takes
                // the next prompt as the start of a turn. A header read would only open a turn
                // from the file's first prompt that the resumed records could wrongly continue.
                self.offset = resume_at;
                self.startup = Startup::Alignment;
                return Ok(());
            }
        }
        let count = usize::try_from((current_size - self.offset).min(max_bytes as u64))
            .unwrap_or(max_bytes);
        let bytes = self.read_at(self.offset, count)?;
        self.offset += bytes.len() as u64;
        self.bytes_read_last_poll = bytes.len();
        self.pending.extend_from_slice(&bytes);

        let Some(newline) = self.pending.iter().position(|byte| *byte == b'\n') else {
            if self.pending.len() > MAX_LINE_BYTES {
                self.pending.clear();
                self.startup = Startup::Unavailable;
                self.is_caught_up = true;
            }
            return Ok(());
        };
        if newline > MAX_LINE_BYTES {
            self.pending.clear();
            self.startup = Startup::Unavailable;
            self.is_caught_up = true;
            return Ok(());
        }
        let header = &self.pending[..newline];
        let parsed = serde_json::from_slice::<serde_json::Value>(header).ok();
        let header_is_valid = match self.tail_header {
            TailHeader::CodexSessionMeta => {
                parsed
                    .as_ref()
                    .and_then(|value| value.get("type"))
                    .and_then(|value| value.as_str())
                    == Some("session_meta")
            }
            TailHeader::AnyTypedEvent => parsed
                .as_ref()
                .and_then(serde_json::Value::as_object)
                .and_then(|value| value.get("type"))
                .and_then(serde_json::Value::as_str)
                .is_some(),
        };
        if !header_is_valid {
            self.pending.clear();
            self.startup = Startup::Unavailable;
            self.is_caught_up = true;
            return Ok(());
        }
        let _ = self.parser.consume(header);
        let header_end = (newline + 1) as u64;
        self.pending.clear();
        if self.parser.excludes_session() {
            self.offset = current_size;
            self.startup = Startup::Ready;
            self.is_caught_up = true;
            return Ok(());
        }
        let tail_start = self.resume_at.take().unwrap_or_else(|| {
            current_size.saturating_sub(self.tail_bytes.unwrap_or(DEFAULT_TAIL_BYTES))
        });
        self.offset = header_end.max(tail_start);
        self.startup = if self.offset > header_end {
            self.parser.begin_mid_file();
            Startup::Alignment
        } else {
            Startup::Ready
        };
        self.is_caught_up = self.startup == Startup::Ready && self.offset >= current_size;
        Ok(())
    }

    fn read_at(&self, offset: u64, count: usize) -> io::Result<Vec<u8>> {
        let mut file = File::open(&self.path)?;
        file.seek(SeekFrom::Start(offset))?;
        let mut bytes = vec![0_u8; count];
        let mut read = 0;
        while read < count {
            match file.read(&mut bytes[read..])? {
                0 => break,
                amount => read += amount,
            }
        }
        bytes.truncate(read);
        Ok(bytes)
    }

    fn collect_parser_output(&mut self) {
        extend_bounded(
            &mut self.delegation_events,
            self.parser.take_delegation_events(),
        );
        let responses = self.parser.take_responses();
        if self.collect_responses {
            self.responses.extend(responses);
            // Bounded in case the host stops draining.
            let excess = self.responses.len().saturating_sub(1_024);
            self.responses.drain(..excess);
        }
    }

    fn consume_complete_lines(&mut self) -> Vec<TurnMetric> {
        let mut records = Vec::new();
        let mut start = 0;
        while let Some(relative_newline) =
            self.pending[start..].iter().position(|byte| *byte == b'\n')
        {
            let newline = start + relative_newline;
            let line_len = newline - start;
            if !self.dropping_oversized_line && line_len <= MAX_LINE_BYTES {
                if let Some(record) = self.parser.consume(&self.pending[start..newline]) {
                    records.push(record);
                }
            }
            self.dropping_oversized_line = false;
            start = newline + 1;
        }
        if start > 0 {
            self.pending.drain(..start);
        }
        if self.pending.len() > MAX_LINE_BYTES {
            self.pending.clear();
            self.dropping_oversized_line = true;
        }
        records
    }

    fn reset_for_current_file(&mut self, identity: Option<FileIdentity>) {
        self.offset = 0;
        self.pending.clear();
        self.dropping_oversized_line = false;
        self.resume_at = None;
        self.identity = identity;
        self.parser.reset(self.path.to_string_lossy().into_owned());
        self.startup = if self.tail_bytes.is_some() {
            Startup::Header
        } else {
            Startup::Beginning
        };
        self.is_caught_up = false;
    }

    pub fn bytes_read_last_poll(&self) -> usize {
        self.bytes_read_last_poll
    }

    pub fn is_caught_up(&self) -> bool {
        self.is_caught_up
    }

    /// Where a later run can resume this reader: the end of what it has consumed, when it is
    /// caught up, holds no partial line and is positioned (or has not yet been touched since it
    /// was resumed). `None` while it still has reading or recovering to do.
    pub fn checkpoint_offset(&self) -> Option<u64> {
        if !self.is_caught_up || !self.pending.is_empty() || self.dropping_oversized_line {
            return None;
        }
        match self.startup {
            Startup::Ready | Startup::Beginning => Some(self.offset),
            Startup::Header => self.resume_at,
            Startup::Alignment | Startup::Unavailable => None,
        }
    }

    pub fn identity(&self) -> Option<&FileIdentity> {
        self.identity.as_ref()
    }

    pub fn excludes_session(&self) -> bool {
        self.parser.excludes_session()
    }

    /// True once a recent-tail reader has chosen its start offset (and again false after a reset
    /// to the beginning of a replaced or truncated file, until it is positioned anew).
    pub fn is_positioned(&self) -> bool {
        self.startup != Startup::Header
    }
}
