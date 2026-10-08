//! Files Tokrate keeps in its own data folder (history, settings, preferences): written whole,
//! readable only by the user.

use std::fs;
use std::io::{self, Write};
use std::path::Path;
use tempfile::NamedTempFile;

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
