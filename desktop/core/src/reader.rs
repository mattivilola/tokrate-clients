use crate::claude_parser::ClaudeTranscriptParser;
use crate::model::TurnMetric;
use crate::parser::{CodexEventParser, JsonlEventParser};
use std::fs::{self, File, Metadata};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::PathBuf;

pub(crate) const MAX_LINE_BYTES: usize = 1_048_576;
const DEFAULT_TAIL_BYTES: u64 = 262_144;

#[derive(Clone, Debug, Eq, PartialEq)]
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
        }
    }

    pub fn poll(&mut self, max_bytes: usize) -> io::Result<Vec<TurnMetric>> {
        self.bytes_read_last_poll = 0;
        if max_bytes == 0 {
            return Ok(Vec::new());
        }
        // Query size and identity from an open handle. Windows path metadata can lag an
        // append while another process still has the JSONL writer open.
        let metadata = File::open(&self.path)?.metadata()?;
        let current_size = metadata.len();
        let current_identity = file_identity(&metadata);
        if current_size < self.offset
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
        if current_size <= self.offset {
            self.is_caught_up =
                self.startup == Startup::Ready || self.startup == Startup::Beginning;
            return Ok(Vec::new());
        }
        if self.startup == Startup::Header {
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
        let tail_start = current_size.saturating_sub(self.tail_bytes.unwrap_or(DEFAULT_TAIL_BYTES));
        self.offset = header_end.max(tail_start);
        self.startup = if self.offset > header_end {
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

    pub fn excludes_session(&self) -> bool {
        self.parser.excludes_session()
    }
}
