use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::Path,
};

pub const CACHE_FILE: &str = "/var/cache/tokrate-headless-updates/status.json";
pub const SETTING_FILE: &str = "/etc/tokrate-headless/update-checks";
const MAX_CACHE_BYTES: usize = 16 * 1024;
const STALE_AFTER: Duration = Duration::hours(36);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CacheRecord {
    pub schema_version: u8,
    pub checked_at: DateTime<Utc>,
    pub installed_version: String,
    pub result: String,
    pub available_version: Option<String>,
    pub release_sequence: Option<u64>,
    #[serde(default)]
    pub release_version: Option<String>,
    pub released_at: Option<DateTime<Utc>>,
    pub expires_at: Option<DateTime<Utc>>,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateSetting {
    Enabled,
    Disabled,
    Unknown,
}

impl UpdateSetting {
    pub fn parse(bytes: &[u8]) -> Self {
        match bytes {
            b"on\n" | b"on" => Self::Enabled,
            b"off\n" | b"off" => Self::Disabled,
            _ => Self::Unknown,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Enabled => "on",
            Self::Disabled => "off",
            Self::Unknown => "unknown",
        }
    }
}

pub fn read_setting_at(path: &Path) -> UpdateSetting {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let Ok(file) = options.open(path) else {
        return UpdateSetting::Unknown;
    };
    if !file.metadata().is_ok_and(|meta| meta.is_file()) {
        return UpdateSetting::Unknown;
    }
    let mut bytes = Vec::new();
    if file.take(32).read_to_end(&mut bytes).is_err() || bytes.len() > 16 {
        return UpdateSetting::Unknown;
    }
    UpdateSetting::parse(&bytes)
}

pub fn read_setting() -> UpdateSetting {
    read_setting_at(Path::new(SETTING_FILE))
}

pub fn read_record_at(path: &Path) -> Option<CacheRecord> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(path).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() == 0 || meta.len() > MAX_CACHE_BYTES as u64 {
        return None;
    }
    let mut bytes = Vec::with_capacity(meta.len() as usize);
    file.take(MAX_CACHE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() > MAX_CACHE_BYTES {
        return None;
    }
    let record = serde_json::from_slice::<CacheRecord>(&bytes).ok()?;
    let installed = super::feed::parse_version(&record.installed_version).ok()?;
    let release_is_consistent = match (record.release_sequence, record.release_version.as_deref()) {
        (Some(sequence), Some(version)) if sequence > 0 => {
            super::feed::parse_version(version).is_ok()
        }
        (None, None) => true,
        _ => false,
    };
    let result_is_consistent = match record.result.as_str() {
        "available" => record
            .available_version
            .as_deref()
            .and_then(|version| super::feed::parse_version(version).ok())
            .is_some_and(|available| {
                available > installed
                    && record.release_version.as_deref() == record.available_version.as_deref()
            }),
        "up-to-date" => {
            record.available_version.is_none()
                && record.release_version.as_deref() == Some(record.installed_version.as_str())
        }
        "error" => record.available_version.is_none(),
        _ => false,
    };
    (record.schema_version == 1 && release_is_consistent && result_is_consistent).then_some(record)
}

pub fn read_record() -> Option<CacheRecord> {
    read_record_at(Path::new(CACHE_FILE))
}

pub fn write_record_at(path: &Path, record: &CacheRecord) -> Result<(), String> {
    let parent = path.parent().ok_or("Update cache path is invalid.")?;
    fs::create_dir_all(parent).map_err(|_| "Could not prepare the public update cache.")?;
    let metadata =
        fs::symlink_metadata(parent).map_err(|_| "Could not inspect the public update cache.")?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err("The public update cache directory is unsafe.".into());
    }
    let mut temp = tempfile::Builder::new()
        .prefix(".status-")
        .tempfile_in(parent)
        .map_err(|_| "Could not write the public update cache.")?;
    let bytes = serde_json::to_vec(record).map_err(|_| "Could not encode update status.")?;
    if bytes.len() > MAX_CACHE_BYTES {
        return Err("Update status exceeded the cache limit.".into());
    }
    temp.write_all(&bytes)
        .map_err(|_| "Could not write the public update cache.")?;
    temp.flush()
        .map_err(|_| "Could not flush the public update cache.")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        temp.as_file()
            .set_permissions(fs::Permissions::from_mode(0o644))
            .map_err(|_| "Could not make public update status readable.")?;
    }
    temp.persist(path)
        .map_err(|_| "Could not publish update status atomically.")?;
    Ok(())
}

pub fn write_record(record: &CacheRecord) -> Result<(), String> {
    write_record_at(Path::new(CACHE_FILE), record)
}

pub fn status_value_at(
    cache_path: &Path,
    setting_path: &Path,
    installed_version: &str,
    now: DateTime<Utc>,
) -> Value {
    let setting = read_setting_at(setting_path);
    let Some(record) = read_record_at(cache_path) else {
        return json!({
            "automaticChecks": setting.as_str(),
            "state": "never-checked",
            "installedVersion": installed_version,
            "availableVersion": null,
            "checkedAt": null,
            "message": "Update availability has not been checked yet."
        });
    };
    let age = now.signed_duration_since(record.checked_at);
    let stale = age < Duration::zero()
        || age > STALE_AFTER
        || record.installed_version != installed_version;
    let state = if stale {
        "stale"
    } else {
        match record.result.as_str() {
            "available" => "available",
            "up-to-date" => "up-to-date",
            _ => "error",
        }
    };
    let message = match state {
        "available" => format!(
            "Update available: {} → {}.",
            record.installed_version,
            record.available_version.as_deref().unwrap_or("unknown")
        ),
        "up-to-date" => format!("Already up to date: {}.", record.installed_version),
        "stale" => "Update check is stale; run check-update to refresh it.".into(),
        _ => "Could not check for updates. Run check-update to try again.".into(),
    };
    json!({
        "automaticChecks": setting.as_str(),
        "state": state,
        "installedVersion": installed_version,
        "availableVersion": if stale { None } else { record.available_version },
        "releaseSequence": record.release_sequence,
        "checkedAt": record.checked_at,
        "message": message
    })
}

pub fn status_value(installed_version: &str) -> Value {
    status_value_at(
        Path::new(CACHE_FILE),
        Path::new(SETTING_FILE),
        installed_version,
        Utc::now(),
    )
}

pub fn record_from_manifest(
    installed_version: &str,
    manifest: &super::feed::Manifest,
    now: DateTime<Utc>,
) -> CacheRecord {
    let current = super::feed::parse_version(installed_version).ok();
    let offered = super::feed::parse_version(&manifest.version).ok();
    let available = offered.zip(current).is_some_and(|(a, c)| a > c);
    CacheRecord {
        schema_version: 1,
        checked_at: now,
        installed_version: installed_version.to_owned(),
        result: if available { "available" } else { "up-to-date" }.into(),
        available_version: available.then(|| manifest.version.clone()),
        release_sequence: Some(manifest.release_sequence),
        release_version: Some(manifest.version.clone()),
        released_at: Some(manifest.released_at),
        expires_at: Some(manifest.expires_at),
        message: if available {
            format!(
                "Update available: {installed_version} → {}.",
                manifest.version
            )
        } else {
            format!("Already up to date: {installed_version}.")
        },
    }
}

pub fn error_record(installed_version: &str, now: DateTime<Utc>) -> CacheRecord {
    CacheRecord {
        schema_version: 1,
        checked_at: now,
        installed_version: installed_version.to_owned(),
        result: "error".into(),
        available_version: None,
        release_sequence: None,
        release_version: None,
        released_at: None,
        expires_at: None,
        message: "Could not check for updates. Run check-update to try again.".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn cache_marks_never_checked_stale_and_current_states_distinctly() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("cache/status.json");
        let setting = dir.path().join("update-checks");
        fs::write(&setting, b"off\n").unwrap();
        let now = Utc.with_ymd_and_hms(2026, 10, 16, 12, 0, 0).unwrap();
        let never = status_value_at(&path, &setting, "0.1.27", now);
        assert_eq!(never["state"], "never-checked");
        assert_eq!(never["automaticChecks"], "off");

        let mut record = CacheRecord {
            schema_version: 1,
            checked_at: now - Duration::hours(37),
            installed_version: "0.1.27".into(),
            result: "available".into(),
            available_version: Some("0.1.28".into()),
            release_sequence: Some(1),
            release_version: Some("0.1.28".into()),
            released_at: None,
            expires_at: None,
            message: "ignored cached text".into(),
        };
        write_record_at(&path, &record).unwrap();
        let stale = status_value_at(&path, &setting, "0.1.27", now);
        assert_eq!(stale["state"], "stale");
        assert!(stale["message"].as_str().unwrap().contains("stale"));
        assert!(!stale["message"].as_str().unwrap().contains("ignored"));

        record.checked_at = now;
        write_record_at(&path, &record).unwrap();
        let available = status_value_at(&path, &setting, "0.1.27", now);
        assert_eq!(available["state"], "available");
        assert_eq!(available["message"], "Update available: 0.1.27 → 0.1.28.");
    }

    #[test]
    fn update_setting_is_independent_and_strict() {
        assert_eq!(UpdateSetting::parse(b"on\n"), UpdateSetting::Enabled);
        assert_eq!(UpdateSetting::parse(b"off"), UpdateSetting::Disabled);
        assert_eq!(UpdateSetting::parse(b"yes"), UpdateSetting::Unknown);
        assert_eq!(UpdateSetting::parse(b"on\nextra"), UpdateSetting::Unknown);
    }
}
