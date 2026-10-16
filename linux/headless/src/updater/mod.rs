mod cache;
mod feed;
mod install;

use crate::config::Result;
use chrono::{Duration, Utc};
use std::{
    fs::{self, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::Path,
    process::Command,
};

pub use cache::status_value;

const SETTINGS_DIR: &str = "/etc/tokrate-headless";
const SETTING_FILE: &str = cache::SETTING_FILE;
const TIMER_UNIT: &str = "tokrate-headless-update-check.timer";
const SERVICE_UNIT: &str = "tokrate-headless-update-check.service";
const INSTALLED_BINARY: &str = "/usr/bin/tokrate-headless";

fn installed_version() -> &'static str {
    tokrate_core::APP_VERSION
}

pub async fn run_check_service() -> Result<()> {
    let now = Utc::now();
    let previous = cache::read_record();
    let outcome = match feed::fetch_manifest(installed_version()).await {
        Ok(manifest) => {
            if verify_release_sequence(&manifest, previous.as_ref()).is_ok() {
                Ok(manifest)
            } else {
                Err(
                    "The signed update release sequence moved backwards or reused a sequence."
                        .to_owned(),
                )
            }
        }
        Err(error) => Err(error),
    };
    let record = match outcome {
        Ok(manifest) => cache::record_from_manifest(installed_version(), &manifest, now),
        Err(_) => {
            let mut record = cache::error_record(installed_version(), now);
            if let Some(previous) = previous {
                record.release_sequence = previous.release_sequence;
                record.release_version = previous.release_version;
                record.released_at = previous.released_at;
                record.expires_at = previous.expires_at;
            }
            record
        }
    };
    cache::write_record(&record).map_err(as_error)?;
    Ok(())
}

pub async fn check_update() -> Result<()> {
    start_check_service()?;
    let record =
        cache::read_record().ok_or("Update check finished without a readable status cache")?;
    let age = Utc::now().signed_duration_since(record.checked_at);
    if age < Duration::zero() || age > Duration::minutes(2) {
        return Err("Update check did not publish a fresh result.".into());
    }
    if record.result == "error" {
        return Err(
            "Could not verify update availability. The previous signed release state was retained."
                .into(),
        );
    }
    if record.result == "available" {
        let available = record
            .available_version
            .as_deref()
            .ok_or("Update status is incomplete")?;
        println!(
            "Update available: {} → {available}",
            record.installed_version
        );
    } else {
        println!("Already up to date: {}", record.installed_version);
    }
    Ok(())
}

pub async fn update_command(expected: Option<&str>, yes: bool) -> Result<()> {
    if unsafe { libc::geteuid() } == 0 {
        return install::update(expected, yes).await;
    }
    if expected.is_some() {
        return Err(
            "The confirmed-version argument is reserved for the root-owned updater.".into(),
        );
    }
    start_check_service()?;
    let record =
        cache::read_record().ok_or("Update check finished without a readable status cache")?;
    let age = Utc::now().signed_duration_since(record.checked_at);
    if age < Duration::zero() || age > Duration::minutes(2) || record.result == "error" {
        return Err("Could not verify the latest update. Run check-update and try again.".into());
    }
    if record.result == "up-to-date" {
        println!("Already up to date: {}", installed_version());
        return Ok(());
    }
    let available = record
        .available_version
        .as_deref()
        .ok_or("The update cache did not include an available version")?;
    let parsed = feed::parse_version(available).map_err(as_error)?;
    let confirmed = parsed.to_string();
    println!("Update available: {} → {confirmed}", installed_version());
    if !yes && !install::confirm()? {
        println!(
            "Update cancelled. Installed version remains {}.",
            installed_version()
        );
        return Ok(());
    }
    install::update_as_user(&confirmed)
}

pub fn update_checks_command(enabled: bool) -> Result<()> {
    if unsafe { libc::geteuid() } == 0 {
        if !is_installed_binary()? {
            return Err(
                "Update-check settings must be changed through /usr/bin/tokrate-headless.".into(),
            );
        }
        set_update_checks(enabled)
    } else {
        let sudo = Path::new("/usr/bin/sudo");
        if !sudo.is_file() {
            return Err("sudo is required to change automatic update checks.".into());
        }
        let mode = if enabled { "on" } else { "off" };
        let status = Command::new(sudo)
            .env_clear()
            .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
            .arg("--")
            .arg(INSTALLED_BINARY)
            .arg("update-checks")
            .arg(mode)
            .status()
            .map_err(|_| "Could not start the privileged update-check setting command")?;
        if !status.success() {
            return Err("Automatic update-check settings were not changed.".into());
        }
        Ok(())
    }
}

pub fn set_update_checks(enabled: bool) -> Result<()> {
    ensure_root_settings_dir()?;
    let path = Path::new(SETTING_FILE);
    let before = read_setting_bytes(path)?;
    if before
        .as_deref()
        .is_some_and(|value| !matches!(value, b"on" | b"on\n" | b"off" | b"off\n"))
    {
        return Err(
            "The root-managed update-check setting is invalid; it was left unchanged.".into(),
        );
    }
    let contents: &[u8] = if enabled { b"on\n" } else { b"off\n" };
    write_root_setting(contents)?;
    if let Err(error) = configure_timer(enabled) {
        restore_setting(before.as_deref())?;
        return Err(error.into());
    }
    println!(
        "Automatic update checks are {}. This setting is independent of community sharing.",
        if enabled { "on" } else { "off" }
    );
    Ok(())
}

pub(super) fn write_setting(enabled: bool) -> Result<()> {
    ensure_root_settings_dir()?;
    let path = Path::new(SETTING_FILE);
    if path.exists() || path.symlink_metadata().is_ok() {
        match cache::read_setting() {
            cache::UpdateSetting::Enabled | cache::UpdateSetting::Disabled => return Ok(()),
            cache::UpdateSetting::Unknown => {
                return Err("The root-managed update-check setting is invalid.".into())
            }
        }
    }
    write_root_setting(if enabled { b"on\n" } else { b"off\n" })
}

pub(super) fn configure_timer(enabled: bool) -> std::result::Result<(), String> {
    let args = if enabled {
        ["enable", "--now", TIMER_UNIT]
    } else {
        ["disable", "--now", TIMER_UNIT]
    };
    let output = Command::new("/usr/bin/systemctl")
        .args(args)
        .env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
        .env("LC_ALL", "C")
        .output()
        .map_err(|_| "Could not configure the update-check timer.")?;
    if output.status.success() {
        Ok(())
    } else {
        Err("Could not configure the update-check timer.".into())
    }
}

fn verify_release_sequence(
    manifest: &feed::Manifest,
    previous: Option<&cache::CacheRecord>,
) -> std::result::Result<(), ()> {
    let Some(previous) = previous else {
        return Ok(());
    };
    let Some(sequence) = previous.release_sequence else {
        return Ok(());
    };
    if manifest.release_sequence < sequence {
        return Err(());
    }
    if manifest.release_sequence == sequence
        && previous
            .release_version
            .as_deref()
            .is_some_and(|old| old != manifest.version)
    {
        return Err(());
    }
    Ok(())
}

fn start_check_service() -> Result<()> {
    let mut command = if unsafe { libc::geteuid() } == 0 {
        Command::new("/usr/bin/systemctl")
    } else {
        let sudo = Path::new("/usr/bin/sudo");
        if !sudo.is_file() {
            return Err("sudo is required to run a manual update check.".into());
        }
        let mut command = Command::new(sudo);
        command.args(["--", "/usr/bin/systemctl"]);
        command
    };
    let output = command
        .args(["start", SERVICE_UNIT])
        .env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
        .env("LC_ALL", "C")
        .output()
        .map_err(|_| "Could not start the isolated update-check service")?;
    if output.status.success() {
        Ok(())
    } else {
        Err("Could not start the isolated update-check service; confirm it is installed and systemd is running.".into())
    }
}

fn is_installed_binary() -> Result<bool> {
    let current = std::env::current_exe()?;
    Ok(fs::canonicalize(current).is_ok_and(|path| path == Path::new(INSTALLED_BINARY)))
}

fn ensure_root_settings_dir() -> Result<()> {
    if unsafe { libc::geteuid() } != 0 {
        return Err("Root privileges are required to change automatic update checks.".into());
    }
    let path = Path::new(SETTINGS_DIR);
    if fs::symlink_metadata(path).is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound) {
        fs::create_dir(path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o755))?;
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 0
        || metadata.mode() & 0o022 != 0
    {
        return Err("The Tokrate settings directory is not a safe root-owned directory.".into());
    }
    Ok(())
}

fn read_setting_bytes(path: &Path) -> Result<Option<Vec<u8>>> {
    let mut options = OpenOptions::new();
    options.read(true);
    options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != 0
        || metadata.mode() & 0o022 != 0
        || metadata.len() > 32
    {
        return Err("The root-managed update-check setting is unsafe.".into());
    }
    let mut bytes = Vec::new();
    file.take(33).read_to_end(&mut bytes)?;
    Ok(Some(bytes))
}

fn write_root_setting(contents: &[u8]) -> Result<()> {
    let path = Path::new(SETTING_FILE);
    let mut temp = tempfile::Builder::new()
        .prefix(".update-checks-")
        .tempfile_in(SETTINGS_DIR)?;
    temp.write_all(contents)?;
    temp.as_file().sync_all()?;
    temp.as_file()
        .set_permissions(fs::Permissions::from_mode(0o644))?;
    temp.persist(path).map_err(|error| error.error)?;
    Ok(())
}

fn restore_setting(bytes: Option<&[u8]>) -> Result<()> {
    match bytes {
        Some(bytes) => write_root_setting(bytes),
        None => match fs::remove_file(SETTING_FILE) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        },
    }
}

fn as_error(message: String) -> Box<dyn std::error::Error + Send + Sync> {
    message.into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setting_parser_rejects_ambiguous_files() {
        assert_eq!(
            cache::UpdateSetting::parse(b"on\n"),
            cache::UpdateSetting::Enabled
        );
        assert_eq!(
            cache::UpdateSetting::parse(b"off\n"),
            cache::UpdateSetting::Disabled
        );
        assert_eq!(
            cache::UpdateSetting::parse(b"on\noff\n"),
            cache::UpdateSetting::Unknown
        );
    }

    #[test]
    fn cached_release_sequence_cannot_move_back_or_change_version() {
        let now = Utc::now();
        let manifest = feed::Manifest {
            schema_version: 1,
            product: "tokrate-headless".into(),
            channel: "alpha".into(),
            version: "0.1.28".into(),
            release_sequence: 1_797_000_000,
            released_at: now - Duration::minutes(5),
            expires_at: now + Duration::days(7),
            minimum_debian: 12,
            platforms: feed::Platforms {
                linux_x86_64_deb: feed::Artifact {
                    url: "https://github.com/mattivilola/tokrate-clients/releases/download/v0.1.28-headless-alpha.1/tokrate-headless_0.1.28_amd64.deb".into(),
                    size: 1024,
                    sha256: "a".repeat(64),
                },
                linux_aarch64_deb: feed::Artifact {
                    url: "https://github.com/mattivilola/tokrate-clients/releases/download/v0.1.28-headless-alpha.1/tokrate-headless_0.1.28_arm64.deb".into(),
                    size: 1024,
                    sha256: "b".repeat(64),
                },
            },
        };
        let previous = cache::record_from_manifest("0.1.27", &manifest, now);
        assert!(verify_release_sequence(&manifest, Some(&previous)).is_ok());
        let mut changed = manifest.clone();
        changed.version = "0.1.29".into();
        assert!(verify_release_sequence(&changed, Some(&previous)).is_err());
        let mut older = manifest.clone();
        older.release_sequence -= 1;
        assert!(verify_release_sequence(&older, Some(&previous)).is_err());
    }
}
