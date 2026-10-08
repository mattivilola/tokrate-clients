//! Files Tokrate keeps in its own data folder (history, settings, preferences): written whole,
//! readable only by the user, and read only as regular files within a size cap.

use crate::reader::{open_regular_file, read_capped};
use std::fs;
use std::io::{self, ErrorKind, Write};
use std::path::Path;
use tempfile::NamedTempFile;

/// The largest settings or preferences file read: they hold a few hundred bytes.
pub const MAX_SMALL_FILE_BYTES: u64 = 1_048_576;

/// The whole content of the app-owned file at `path`, which must be a regular file of at most
/// `cap` bytes. A missing file is `NotFound`; a pipe, folder or device is `InvalidInput` (opened
/// without waiting for a writer and never read); a file over the cap, including one that grew
/// after it was opened, is `InvalidData`.
pub fn read_private_file<P: AsRef<Path>>(path: P, cap: u64) -> io::Result<Vec<u8>> {
    let (file, _) = open_regular_file(path.as_ref())?;
    read_capped(file, cap)?
        .ok_or_else(|| io::Error::new(ErrorKind::InvalidData, "file exceeds the size limit"))
}

/// Writes `data` as the whole content of `path`: to a temporary file in the same folder, which
/// replaces `path` only once it is complete. The temporary file is created readable by its owner
/// only on Unix, so the result is too, even when `path` existed with wider permissions. A missing
/// folder is created.
pub fn write_private_file<P: AsRef<Path>>(path: P, data: &[u8]) -> io::Result<()> {
    let path = path.as_ref();
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent)?;
    let mut temporary = NamedTempFile::new_in(parent)?;
    temporary.write_all(data)?;
    temporary.as_file().sync_all()?;
    temporary.persist(path).map_err(|error| error.error)?;
    Ok(())
}
