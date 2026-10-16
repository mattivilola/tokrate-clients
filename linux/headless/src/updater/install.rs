use super::{cache, feed};
use crate::{config::Result, updater};
use chrono::Utc;
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::Digest;
use std::{
    collections::BTreeMap,
    ffi::OsStr,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::{Command, Output},
    thread,
    time::{Duration, Instant},
};

const BIN: &str = "/usr/bin/tokrate-headless";
const UNIT_DIR: &str = "/usr/lib/systemd/system";
const LOCK_DIR: &str = "/run/tokrate-headless";
const LOCK_FILE: &str = "/run/tokrate-headless/update.lock";
const HIGH_WATER_DIR: &str = "/var/lib/tokrate-headless-updates";
const HIGH_WATER_FILE: &str = "/var/lib/tokrate-headless-updates/accepted-release.json";
const LOCAL_TEMPLATE: &str = "tokrate-headless-local@.service";
const SHARE_TEMPLATE: &str = "tokrate-headless-share@.service";
const UPDATE_CHECK_SERVICE: &str = "tokrate-headless-update-check.service";
const UPDATE_CHECK_TIMER: &str = "tokrate-headless-update-check.timer";
const SAFE_PATH: &str = "/usr/sbin:/usr/bin:/sbin:/bin";

#[derive(Debug, Clone)]
struct ServiceState {
    unit: String,
    account: String,
    mode: &'static str,
    enabled_state: String,
    was_active: bool,
}

#[derive(Debug, Clone, Copy)]
struct TimerSnapshot {
    enabled: bool,
    active: bool,
}

#[derive(Debug, Clone, Copy)]
struct CheckerSnapshot {
    timer: Option<TimerSnapshot>,
    service_active: Option<bool>,
}

pub async fn update(expected: Option<&str>, yes: bool) -> Result<()> {
    ensure_installed_root_binary()?;
    let _lock = acquire_update_lock()?;
    let current = installed_binary_version()?;
    let manifest = feed::fetch_manifest(&current).await.map_err(as_error)?;
    verify_high_water(&manifest)?;
    let target = &manifest.version;
    if feed::parse_version(target).map_err(as_error)?
        == feed::parse_version(&current).map_err(as_error)?
    {
        write_high_water(&manifest)?;
        if expected.is_some() {
            return Err(
                "The confirmed update is no longer available; no files were changed.".into(),
            );
        }
        println!("Already up to date: {current}");
        return Ok(());
    }
    if expected.is_some_and(|confirmed| confirmed != target) {
        return Err(
            "The verified update version changed after confirmation; no files were changed.".into(),
        );
    }
    println!("Update available: {current} → {target}");
    if !yes && !confirm()? {
        println!("Update cancelled. Installed version remains {current}.");
        return Ok(());
    }

    ensure_minimum_os(manifest.minimum_debian)?;

    // Re-fetch and signature validation above happen inside the root-owned installed binary.
    // Only after the administrator accepts the exact version do we download the package.
    let artifact_bytes = feed::download_artifact(&manifest).await.map_err(as_error)?;
    let artifact = manifest.artifact_for_current_arch().map_err(as_error)?;
    let stage = tempfile::Builder::new()
        .prefix("tokrate-headless-update-")
        .tempdir_in("/var/tmp")
        .map_err(|_| "Could not create private update staging.")?;
    fs::set_permissions(stage.path(), fs::Permissions::from_mode(0o700))
        .map_err(|_| "Could not secure private update staging.")?;
    let package = stage.path().join("tokrate-headless.deb");
    write_private(&package, &artifact_bytes, 0o600)?;
    verify_deb(&package, target, artifact.size, artifact.sha256.as_str())?;
    let services = enumerate_services()?;
    let rollback = build_rollback_package(stage.path())?;
    let checker_snapshot = capture_checker_state()?;
    write_high_water(&manifest)?;
    let previous = current.to_owned();
    for service in services.iter().filter(|service| service.was_active) {
        let stop_succeeded = systemctl(&["stop", &service.unit]).is_ok();
        let stopped = show_property(&service.unit, "ActiveState")
            .is_ok_and(|state| matches!(state.as_str(), "inactive" | "failed"));
        if !stop_succeeded || !stopped {
            let recovered = restart_services(&services, &previous);
            return Err(if recovered {
                format!("Could not stop {} safely; the update was cancelled and previously active services are running.", service.unit).into()
            } else {
                format!("Could not stop {} safely, and service recovery could not be confirmed. Check the Tokrate services before relying on them.", service.unit).into()
            });
        }
    }
    if let Err(error) = stop_checker(&checker_snapshot) {
        let services_recovered = restart_services(&services, &previous);
        let checker_recovered = restore_checker(&checker_snapshot);
        return Err(if services_recovered && checker_recovered {
            format!(
                "Could not stop the update-check units safely; the update was cancelled: {error}"
            )
            .into()
        } else {
            "Could not stop the update-check units safely, and recovery could not be confirmed. Check Tokrate services before relying on them.".into()
        });
    }

    let install_result = command_output(
        "/usr/bin/dpkg",
        &[OsStr::new("--install"), package.as_os_str()],
    );
    if !install_result
        .as_ref()
        .is_ok_and(|out| out.status.success())
    {
        let recovered = restart_previous(&services, &rollback, &previous, &checker_snapshot);
        return Err(if recovered {
            "Package installation failed. The previous binary and active services were restored."
                .into()
        } else {
            "Package installation failed, and rollback could not be confirmed. Check the Tokrate services before relying on them.".into()
        });
    }

    if !installed_binary_version().is_ok_and(|installed| installed == *target) {
        let recovered = restart_previous(&services, &rollback, &previous, &checker_snapshot);
        return Err(if recovered {
            "The installed package did not report the verified version. The previous version was restored.".into()
        } else {
            "The installed package version could not be verified, and rollback could not be confirmed.".into()
        });
    }

    let setting_was_missing = cache::read_setting() == cache::UpdateSetting::Unknown
        && !Path::new(cache::SETTING_FILE).exists();
    if setting_was_missing {
        if let Err(error) = updater::write_setting(true) {
            let recovered = restart_previous(&services, &rollback, &previous, &checker_snapshot);
            return Err(if recovered {
                format!("The package was verified, but update-check setup failed; the previous version was restored: {error}").into()
            } else {
                "Update-check setup failed, and rollback could not be confirmed.".into()
            });
        }
    }
    let setting = cache::read_setting();
    if setting == cache::UpdateSetting::Unknown {
        let recovered = restart_previous(&services, &rollback, &previous, &checker_snapshot);
        return Err(if recovered {
            "The update-check setting is invalid. The previous version was restored.".into()
        } else {
            "The update-check setting is invalid, and rollback could not be confirmed.".into()
        });
    }
    if !service_enablement_matches(&services) || !services_are_stopped(&services) {
        let recovered = restart_previous(&services, &rollback, &previous, &checker_snapshot);
        return Err(if recovered {
            "Service enablement or stopped state changed during package installation. The previous version was restored.".into()
        } else {
            "Service state changed during package installation, and rollback could not be confirmed. Check the Tokrate services before relying on them.".into()
        });
    }

    let mut restarted: Vec<String> = Vec::new();
    let restart_started_at = Utc::now();
    for service in services.iter().filter(|service| service.was_active) {
        if systemctl(&["start", &service.unit]).is_err()
            || !matches!(show_property(&service.unit, "ActiveState"), Ok(ref state) if state == "active")
            || !service_uses_installed_binary(&service.unit)
            || !wait_for_heartbeat(&service.account, target, restart_started_at)
        {
            for unit in restarted.iter().rev() {
                let _ = systemctl(&["stop", unit]);
            }
            let recovered = restart_previous(&services, &rollback, &previous, &checker_snapshot);
            return Err(if recovered {
                format!("Update failed health checks. Version {previous} was restored and previously active services are running.").into()
            } else {
                "Update failed health checks, and rollback could not be confirmed. Check the Tokrate services before relying on them.".into()
            });
        }
        restarted.push(service.unit.clone());
    }

    if !service_states_match(&services) {
        let recovered = restart_previous(&services, &rollback, &previous, &checker_snapshot);
        return Err(if recovered {
            "Service enablement or stopped state changed during restart. The previous version was restored.".into()
        } else {
            "Service state changed during restart, and rollback could not be confirmed. Check the Tokrate services before relying on them.".into()
        });
    }

    if let Err(error) = updater::configure_timer(setting == cache::UpdateSetting::Enabled) {
        let recovered = restart_previous(&services, &rollback, &previous, &checker_snapshot);
        return Err(if recovered {
            format!("Could not configure automatic update checks; the previous version was restored: {error}").into()
        } else {
            "Could not configure automatic update checks, and rollback could not be confirmed."
                .into()
        });
    }

    if restarted.is_empty() {
        println!("Updated {previous} → {target}. No monitoring services were active.");
    } else if restarted.len() == 1 {
        println!(
            "Updated {previous} → {target}; {} service restarted and running.",
            restarted[0]
        );
    } else {
        println!(
            "Updated {previous} → {target}; {} services restarted and running.",
            restarted.len()
        );
    }
    println!("Automatic update checks: {}.", setting.as_str());
    Ok(())
}

pub fn update_as_user(expected: &str) -> Result<()> {
    let version = feed::parse_version(expected).map_err(as_error)?;
    let version_text = version.to_string();
    let sudo = if Path::new("/usr/bin/sudo").is_file() {
        "/usr/bin/sudo"
    } else {
        return Err("sudo is required to install the verified package.".into());
    };
    let mut command = Command::new(sudo);
    command
        .env_clear()
        .env("PATH", SAFE_PATH)
        .arg("--")
        .arg(BIN)
        .arg("update")
        .arg("--confirmed-version")
        .arg(version_text)
        .arg("--yes");
    let status = command
        .status()
        .map_err(|_| "Could not start the privileged Tokrate updater.")?;
    if !status.success() {
        return Err("The privileged update did not complete successfully.".into());
    }
    Ok(())
}

pub(super) fn confirm() -> Result<bool> {
    use std::io::{self, IsTerminal};
    if !io::stdin().is_terminal() {
        return Err(
            "An interactive confirmation is required; use update --yes to confirm explicitly."
                .into(),
        );
    }
    print!("Install this update now? [y/N] ");
    io::stdout().flush()?;
    let mut response = String::new();
    io::stdin().read_line(&mut response)?;
    Ok(matches!(
        response.trim().to_ascii_lowercase().as_str(),
        "y" | "yes"
    ))
}

fn ensure_installed_root_binary() -> Result<()> {
    let current_exe = std::env::current_exe()?;
    let canonical = fs::canonicalize(&current_exe)?;
    if canonical != Path::new(BIN) {
        return Err(
            "Updates must run through the installed /usr/bin/tokrate-headless binary.".into(),
        );
    }
    let metadata = fs::symlink_metadata(BIN)?;
    if !metadata.is_file() || metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
        return Err("The installed Tokrate updater is not a safe root-owned executable.".into());
    }
    Ok(())
}

fn acquire_update_lock() -> Result<File> {
    let parent = Path::new(LOCK_DIR);
    if fs::symlink_metadata(parent).is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
    {
        match fs::create_dir(parent) {
            Ok(()) => fs::set_permissions(parent, fs::Permissions::from_mode(0o755))?,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
    }
    let parent_metadata = fs::symlink_metadata(parent)?;
    if !parent_metadata.is_dir()
        || parent_metadata.file_type().is_symlink()
        || parent_metadata.uid() != 0
        || parent_metadata.mode() & 0o022 != 0
    {
        return Err("The system update lock directory is not safe.".into());
    }
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true);
    options.mode(0o600);
    options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    let file = options
        .open(LOCK_FILE)
        .map_err(|_| "Could not open the system update lock safely.")?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.uid() != 0 || metadata.mode() & 0o077 != 0 {
        return Err("The system update lock is not a private root-owned file.".into());
    }
    file.lock_exclusive()
        .map_err(|_| "Could not acquire the system update lock.")?;
    Ok(file)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct HighWater {
    schema_version: u8,
    release_sequence: u64,
    version: String,
}

fn ensure_high_water_dir() -> Result<()> {
    let path = Path::new(HIGH_WATER_DIR);
    if fs::symlink_metadata(path).is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound) {
        match fs::create_dir(path) {
            Ok(()) => fs::set_permissions(path, fs::Permissions::from_mode(0o755))?,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != 0
        || metadata.mode() & 0o022 != 0
    {
        return Err("The root-managed update history directory is unsafe.".into());
    }
    Ok(())
}

fn read_high_water() -> Result<Option<HighWater>> {
    ensure_high_water_dir()?;
    let mut options = OpenOptions::new();
    options.read(true);
    options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    let file = match options.open(HIGH_WATER_FILE) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("The root-managed update history file is unsafe.".into()),
    };
    let metadata = file.metadata()?;
    if !metadata.is_file()
        || metadata.uid() != 0
        || metadata.mode() & 0o077 != 0
        || metadata.len() == 0
        || metadata.len() > 4096
    {
        return Err("The root-managed update history file is unsafe.".into());
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(4097).read_to_end(&mut bytes)?;
    if bytes.len() > 4096 {
        return Err("The root-managed update history file is too large.".into());
    }
    let record: HighWater = serde_json::from_slice(&bytes)
        .map_err(|_| "The root-managed update history file is invalid.")?;
    if record.schema_version != 1
        || record.release_sequence == 0
        || feed::parse_version(&record.version).is_err()
    {
        return Err("The root-managed update history file is invalid.".into());
    }
    Ok(Some(record))
}

fn verify_high_water(manifest: &feed::Manifest) -> Result<()> {
    let Some(previous) = read_high_water()? else {
        return Ok(());
    };
    if !release_is_at_least(
        manifest.release_sequence,
        &manifest.version,
        previous.release_sequence,
        &previous.version,
    )? {
        return Err("The signed release is older than the root-accepted update history.".into());
    }
    Ok(())
}

fn release_is_at_least(
    candidate_sequence: u64,
    candidate_version: &str,
    previous_sequence: u64,
    previous_version: &str,
) -> Result<bool> {
    let candidate = feed::parse_version(candidate_version).map_err(as_error)?;
    let previous = feed::parse_version(previous_version).map_err(as_error)?;
    Ok(candidate_sequence >= previous_sequence
        && candidate >= previous
        && (candidate_sequence != previous_sequence || candidate == previous))
}

fn write_high_water(manifest: &feed::Manifest) -> Result<()> {
    verify_high_water(manifest)?;
    let record = HighWater {
        schema_version: 1,
        release_sequence: manifest.release_sequence,
        version: manifest.version.clone(),
    };
    let bytes = serde_json::to_vec(&record)?;
    let mut temp = tempfile::Builder::new()
        .prefix(".accepted-release-")
        .tempfile_in(HIGH_WATER_DIR)?;
    temp.write_all(&bytes)?;
    temp.as_file().sync_all()?;
    temp.as_file()
        .set_permissions(fs::Permissions::from_mode(0o600))?;
    temp.persist(HIGH_WATER_FILE).map_err(|error| error.error)?;
    Ok(())
}

fn ensure_minimum_os(minimum_debian: u16) -> Result<()> {
    let release = fs::read_to_string("/etc/os-release")
        .map_err(|_| "Could not determine the installed Debian-compatible OS version.")?;
    let mut id = None;
    let mut version = None;
    for line in release.lines() {
        if let Some(value) = line.strip_prefix("ID=") {
            id = Some(value.trim_matches('"'));
        } else if let Some(value) = line.strip_prefix("VERSION_ID=") {
            version = Some(value.trim_matches('"'));
        }
    }
    let supported_id = matches!(id, Some("debian" | "ubuntu"));
    let major = version
        .and_then(|value| value.split('.').next())
        .and_then(|value| value.parse::<u16>().ok());
    if !supported_id || major.is_none_or(|major| major < minimum_debian) {
        return Err(format!(
            "This signed package requires Debian-compatible version {minimum_debian} or newer."
        )
        .into());
    }
    Ok(())
}

fn installed_binary_version() -> Result<String> {
    let output = command_output(BIN, &[OsStr::new("--version")])?;
    if !output.status.success() {
        return Err("Could not verify the installed Tokrate binary version.".into());
    }
    let version = String::from_utf8_lossy(&output.stdout)
        .trim()
        .strip_prefix("tokrate-headless ")
        .ok_or("The installed Tokrate binary returned an invalid version.")?
        .to_owned();
    feed::parse_version(&version).map_err(as_error)?;
    Ok(version)
}

fn command_output(program: &str, args: &[&OsStr]) -> Result<Output> {
    Command::new(program)
        .args(args)
        .env_clear()
        .env("PATH", SAFE_PATH)
        .env("LC_ALL", "C")
        .output()
        .map_err(Into::into)
}

fn systemctl(args: &[&str]) -> Result<Output> {
    let args: Vec<_> = args.iter().map(OsStr::new).collect();
    let output = command_output("/usr/bin/systemctl", &args)?;
    if output.status.success() {
        Ok(output)
    } else {
        Err("systemctl command failed".into())
    }
}

fn show_property(unit: &str, property: &str) -> Result<String> {
    let output = systemctl(&["show", "--property", property, "--value", unit])?;
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn enumerate_services() -> Result<Vec<ServiceState>> {
    let files = systemctl(&[
        "list-unit-files",
        "--type=service",
        "--no-legend",
        "--no-pager",
    ])?;
    let loaded = systemctl(&[
        "list-units",
        "--type=service",
        "--all",
        "--no-legend",
        "--no-pager",
    ])?;
    let files = String::from_utf8(files.stdout)
        .map_err(|_| "systemd returned invalid unit-file inventory.")?;
    let loaded = String::from_utf8(loaded.stdout)
        .map_err(|_| "systemd returned invalid loaded-unit inventory.")?;
    let units = service_inventory_units(&files, &loaded);
    let mut services = Vec::new();
    for (unit, (mode, account)) in units {
        let enabled_state = show_property(&unit, "UnitFileState")?;
        if enabled_state.is_empty() {
            return Err("systemd returned an empty Tokrate unit enablement state.".into());
        }
        let active = show_property(&unit, "ActiveState")?;
        services.push(ServiceState {
            unit,
            account,
            mode,
            enabled_state,
            was_active: matches!(
                active.as_str(),
                "active" | "activating" | "reloading" | "deactivating"
            ),
        });
    }
    Ok(services)
}

fn service_inventory_units(
    unit_files: &str,
    loaded_units: &str,
) -> BTreeMap<String, (&'static str, String)> {
    let mut units = BTreeMap::new();
    for line in unit_files.lines() {
        if let Some(unit) = line.split_whitespace().next() {
            insert_service_unit(&mut units, unit);
        }
    }
    for line in loaded_units.lines() {
        let mut columns = line.split_whitespace();
        let Some(unit) = columns.next() else { continue };
        let Some(load_state) = columns.next() else {
            continue;
        };
        if load_state == "loaded" {
            insert_service_unit(&mut units, unit);
        }
    }
    units
}

fn insert_service_unit(units: &mut BTreeMap<String, (&'static str, String)>, unit: &str) {
    let Some((mode, account)) = split_service(unit) else {
        return;
    };
    if account
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"_.-$".contains(&byte))
    {
        units.insert(unit.to_owned(), (mode, account.to_owned()));
    }
}

fn split_service(unit: &str) -> Option<(&'static str, &str)> {
    for (prefix, mode) in [
        ("tokrate-headless-local@", "local"),
        ("tokrate-headless-share@", "share"),
    ] {
        if let Some(account) = unit
            .strip_prefix(prefix)
            .and_then(|s| s.strip_suffix(".service"))
        {
            if !account.contains('@') && !account.is_empty() {
                return Some((mode, account));
            }
        }
    }
    None
}

fn write_private(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    options.mode(mode);
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}

fn verify_deb(path: &Path, version: &str, size: u64, expected_digest: &str) -> Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file()
        || metadata.uid() != 0
        || metadata.mode() & 0o077 != 0
        || metadata.len() != size
    {
        return Err("The staged update package is unsafe or has the wrong size.".into());
    }
    let package = package_field(path, "Package")?;
    let package_version = package_field(path, "Version")?;
    let architecture = package_field(path, "Architecture")?;
    if package != "tokrate-headless" || package_version != version || architecture != deb_arch()? {
        return Err("The downloaded Debian package identity did not match the signed feed.".into());
    }
    let bytes = fs::read(path)?;
    let digest = hex::encode(sha2::Sha256::digest(&bytes));
    if !digest.eq_ignore_ascii_case(expected_digest) {
        return Err("The staged package digest did not match the signed feed.".into());
    }
    Ok(())
}

fn package_field(path: &Path, field: &str) -> Result<String> {
    let output = command_output(
        "/usr/bin/dpkg-deb",
        &[OsStr::new("--field"), path.as_os_str(), OsStr::new(field)],
    )?;
    if !output.status.success() {
        return Err("The downloaded Debian package is invalid.".into());
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if value.is_empty() || value.contains(['\n', '\r', '\0']) {
        return Err("The downloaded Debian package has invalid metadata.".into());
    }
    Ok(value)
}

fn deb_arch() -> Result<String> {
    let output = command_output("/usr/bin/dpkg", &[OsStr::new("--print-architecture")])?;
    if !output.status.success() {
        return Err("Could not determine the Debian architecture.".into());
    }
    let arch = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if !matches!(arch.as_str(), "amd64" | "arm64") {
        return Err("This Debian architecture is not supported by Tokrate updates.".into());
    }
    Ok(arch)
}

fn build_rollback_package(stage: &Path) -> Result<PathBuf> {
    let root = stage.join("rollback-root");
    fs::create_dir_all(root.join("DEBIAN"))?;
    fs::create_dir_all(root.join("usr/bin"))?;
    fs::create_dir_all(root.join("lib/systemd/system"))?;
    let has_check_service = safe_unit_file(UPDATE_CHECK_SERVICE)?.is_some();
    let has_check_timer = safe_unit_file(UPDATE_CHECK_TIMER)?.is_some();
    let units = rollback_unit_names(has_check_service, has_check_timer)
        .map_err(|_| "Cannot prepare rollback because only one update-check unit is installed.")?;
    let binary = Path::new(BIN);
    let meta = fs::symlink_metadata(binary)?;
    if !meta.is_file() || meta.uid() != 0 || meta.mode() & 0o022 != 0 {
        return Err("The current Tokrate binary is not safe for rollback staging.".into());
    }
    fs::copy(binary, root.join("usr/bin/tokrate-headless"))?;
    for template in &units {
        let source = Path::new(UNIT_DIR).join(template);
        let metadata = fs::symlink_metadata(&source)
            .map_err(|_| format!("Cannot prepare rollback because {template} is missing."))?;
        if !metadata.is_file() || metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
            return Err(format!("Cannot prepare rollback because {template} is unsafe.").into());
        }
        fs::copy(source, root.join("lib/systemd/system").join(template))?;
    }
    fs::set_permissions(
        root.join("usr/bin/tokrate-headless"),
        fs::Permissions::from_mode(0o755),
    )?;
    for template in &units {
        fs::set_permissions(
            root.join("lib/systemd/system").join(template),
            fs::Permissions::from_mode(0o644),
        )?;
    }
    let version = installed_binary_version()?;
    let arch = deb_arch()?;
    let control = format!(
        "Package: tokrate-headless\nVersion: {version}\nSection: net\nPriority: optional\nArchitecture: {arch}\nDepends: libc6 (>= 2.36), libgcc-s1, systemd (>= 252)\nMaintainer: Tokrate maintainers\nDescription: Local coding-session speed monitor for headless Linux servers\n"
    );
    write_private(&root.join("DEBIAN/control"), control.as_bytes(), 0o644)?;
    let postinst = b"#!/bin/sh\nset -e\nif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload; fi\nexit 0\n";
    write_private(&root.join("DEBIAN/postinst"), postinst, 0o755)?;
    let package = stage.join("tokrate-headless-rollback.deb");
    let output = command_output(
        "/usr/bin/dpkg-deb",
        &[
            OsStr::new("--build"),
            OsStr::new("--root-owner-group"),
            root.as_os_str(),
            package.as_os_str(),
        ],
    )?;
    if !output.status.success() {
        return Err("Could not prepare a local rollback package.".into());
    }
    Ok(package)
}

fn safe_unit_file(unit: &str) -> Result<Option<fs::Metadata>> {
    let path = Path::new(UNIT_DIR).join(unit);
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if !metadata.is_file() || metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
        return Err(format!("The installed {unit} unit file is unsafe.").into());
    }
    Ok(Some(metadata))
}

fn rollback_unit_names(
    has_check_service: bool,
    has_check_timer: bool,
) -> std::result::Result<Vec<&'static str>, ()> {
    if has_check_service != has_check_timer {
        return Err(());
    }
    let mut units = vec![LOCAL_TEMPLATE, SHARE_TEMPLATE];
    if has_check_service {
        units.extend([UPDATE_CHECK_SERVICE, UPDATE_CHECK_TIMER]);
    }
    Ok(units)
}

fn capture_checker_state() -> Result<CheckerSnapshot> {
    let timer = if safe_unit_file(UPDATE_CHECK_TIMER)?.is_some() {
        let enabled = match show_property(UPDATE_CHECK_TIMER, "UnitFileState")?.as_str() {
            "enabled" => true,
            "disabled" => false,
            _ => return Err("The update-check timer has an unsupported enablement state.".into()),
        };
        let active = match show_property(UPDATE_CHECK_TIMER, "ActiveState")?.as_str() {
            "active" => true,
            "inactive" | "failed" => false,
            _ => return Err("The update-check timer has an unsupported running state.".into()),
        };
        Some(TimerSnapshot { enabled, active })
    } else {
        None
    };
    let service_active = if safe_unit_file(UPDATE_CHECK_SERVICE)?.is_some() {
        let active = match show_property(UPDATE_CHECK_SERVICE, "ActiveState")?.as_str() {
            "active" | "activating" | "reloading" | "deactivating" => true,
            "inactive" | "failed" => false,
            _ => return Err("The update-check service has an unsupported running state.".into()),
        };
        Some(active)
    } else {
        None
    };
    Ok(CheckerSnapshot {
        timer,
        service_active,
    })
}

fn stop_checker(snapshot: &CheckerSnapshot) -> Result<()> {
    if snapshot.timer.is_some() {
        systemctl(&["stop", UPDATE_CHECK_TIMER])?;
        if !matches!(
            show_property(UPDATE_CHECK_TIMER, "ActiveState")?.as_str(),
            "inactive" | "failed"
        ) {
            return Err("The update-check timer did not stop cleanly.".into());
        }
    }
    if snapshot.service_active.is_some() {
        systemctl(&["stop", UPDATE_CHECK_SERVICE])?;
        if !matches!(
            show_property(UPDATE_CHECK_SERVICE, "ActiveState")?.as_str(),
            "inactive" | "failed"
        ) {
            return Err("The update-check service did not stop cleanly.".into());
        }
    }
    Ok(())
}

fn restore_checker(snapshot: &CheckerSnapshot) -> bool {
    let mut restored = true;
    match snapshot.timer {
        Some(timer) => {
            let (enable_action, active_action) = timer_recovery_actions(timer);
            if systemctl(&[enable_action, UPDATE_CHECK_TIMER]).is_err() {
                restored = false;
            }
            if systemctl(&[active_action, UPDATE_CHECK_TIMER]).is_err() {
                restored = false;
            }
            let expected_enabled = if timer.enabled { "enabled" } else { "disabled" };
            if !show_property(UPDATE_CHECK_TIMER, "UnitFileState")
                .is_ok_and(|state| state == expected_enabled)
            {
                restored = false;
            }
            if !show_property(UPDATE_CHECK_TIMER, "ActiveState").is_ok_and(|state| {
                if timer.active {
                    state == "active"
                } else {
                    state == "inactive" || state == "failed"
                }
            }) {
                restored = false;
            }
        }
        None => match safe_unit_file(UPDATE_CHECK_TIMER) {
            Ok(None) => {}
            _ => restored = false,
        },
    }
    match snapshot.service_active {
        Some(true) => {
            if systemctl(&["start", UPDATE_CHECK_SERVICE]).is_err() {
                restored = false;
            }
        }
        Some(false) => {
            if systemctl(&["stop", UPDATE_CHECK_SERVICE]).is_err()
                || !show_property(UPDATE_CHECK_SERVICE, "ActiveState")
                    .is_ok_and(|state| state == "inactive" || state == "failed")
            {
                restored = false;
            }
        }
        None => match safe_unit_file(UPDATE_CHECK_SERVICE) {
            Ok(None) => {}
            _ => restored = false,
        },
    }
    restored
}

fn timer_recovery_actions(snapshot: TimerSnapshot) -> (&'static str, &'static str) {
    (
        if snapshot.enabled {
            "enable"
        } else {
            "disable"
        },
        if snapshot.active { "start" } else { "stop" },
    )
}

fn restart_previous(
    services: &[ServiceState],
    rollback: &Path,
    version: &str,
    checker_snapshot: &CheckerSnapshot,
) -> bool {
    if stop_checker(checker_snapshot).is_err() {
        return false;
    }
    for service in services {
        match show_property(&service.unit, "ActiveState") {
            Ok(state) if state == "inactive" || state == "failed" => {}
            Ok(_) => {
                if systemctl(&["stop", &service.unit]).is_err()
                    || !matches!(show_property(&service.unit, "ActiveState"), Ok(ref state) if state == "inactive" || state == "failed")
                {
                    return false;
                }
            }
            Err(_) => return false,
        }
    }
    let rollback_ok = command_output(
        "/usr/bin/dpkg",
        &[OsStr::new("--install"), rollback.as_os_str()],
    )
    .is_ok_and(|out| out.status.success())
        && installed_binary_version().is_ok_and(|installed| installed == version);
    let _ = systemctl(&["daemon-reload"]);
    let services_ok = restart_services(services, version);
    let checker_ok = restore_checker(checker_snapshot);
    rollback_ok && services_ok && checker_ok
}

fn restart_services(services: &[ServiceState], version: &str) -> bool {
    let mut ok = true;
    let restart_started_at = Utc::now();
    for service in services.iter().filter(|service| service.was_active) {
        if systemctl(&["start", &service.unit]).is_err()
            || !matches!(show_property(&service.unit, "ActiveState"), Ok(ref state) if state == "active")
            || !service_uses_installed_binary(&service.unit)
            || !wait_for_heartbeat(&service.account, version, restart_started_at)
        {
            ok = false;
        }
    }
    ok && service_states_match(services)
}

fn service_states_match(services: &[ServiceState]) -> bool {
    services.iter().all(|service| {
        if service.mode.is_empty() {
            return false;
        }
        match (
            show_property(&service.unit, "UnitFileState"),
            show_property(&service.unit, "ActiveState"),
        ) {
            (Ok(enabled), Ok(active)) => service_state_matches(
                &service.enabled_state,
                service.was_active,
                &enabled,
                &active,
            ),
            _ => false,
        }
    })
}

fn service_enablement_matches(services: &[ServiceState]) -> bool {
    services.iter().all(|service| {
        !service.mode.is_empty()
            && !service.enabled_state.is_empty()
            && show_property(&service.unit, "UnitFileState")
                .is_ok_and(|state| state == service.enabled_state)
    })
}

fn services_are_stopped(services: &[ServiceState]) -> bool {
    services.iter().all(|service| {
        show_property(&service.unit, "ActiveState")
            .is_ok_and(|state| state == "inactive" || state == "failed")
    })
}

fn service_state_matches(
    expected_enabled: &str,
    expected_active: bool,
    actual_enabled: &str,
    actual_active: &str,
) -> bool {
    expected_enabled == actual_enabled
        && if expected_active {
            actual_active == "active"
        } else {
            actual_active == "inactive" || actual_active == "failed"
        }
}

fn service_uses_installed_binary(unit: &str) -> bool {
    let Ok(pid) = show_property(unit, "MainPID") else {
        return false;
    };
    let Ok(pid) = pid.parse::<u32>() else {
        return false;
    };
    if pid <= 1 {
        return false;
    }
    let Ok(running) = fs::metadata(format!("/proc/{pid}/exe")) else {
        return false;
    };
    let Ok(installed) = fs::metadata(BIN) else {
        return false;
    };
    running.dev() == installed.dev()
        && running.ino() == installed.ino()
        && show_property(unit, "MainPID").is_ok_and(|current| current == pid.to_string())
}

fn wait_for_heartbeat(account: &str, version: &str, started_at: chrono::DateTime<Utc>) -> bool {
    let path = Path::new("/var/lib/tokrate-headless")
        .join(account)
        .join("status.json");
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if let Some(status) = read_daemon_status(&path) {
            let heartbeat_is_fresh = status["updated_at"]
                .as_str()
                .and_then(|value| chrono::DateTime::parse_from_rfc3339(value).ok())
                .is_some_and(|value| {
                    value.timestamp_millis() >= started_at.timestamp_millis() - 1_000
                });
            if status["version"] == version && status["monitoring"] == true && heartbeat_is_fresh {
                return true;
            }
        }
        thread::sleep(Duration::from_millis(500));
    }
    false
}

fn read_daemon_status(path: &Path) -> Option<Value> {
    let mut options = OpenOptions::new();
    options.read(true);
    options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    let file = options.open(path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > 1_048_576 {
        return None;
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(1_048_577).read_to_end(&mut bytes).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn as_error(message: String) -> Box<dyn std::error::Error + Send + Sync> {
    message.into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_matcher_accepts_only_known_templates() {
        assert_eq!(
            split_service("tokrate-headless-local@alice.service"),
            Some(("local", "alice"))
        );
        assert_eq!(
            split_service("tokrate-headless-share@build-user.service"),
            Some(("share", "build-user"))
        );
        assert_eq!(split_service("tokrate-headless-update-check.service"), None);
        assert_eq!(split_service("other@alice.service"), None);
        assert_eq!(
            split_service("tokrate-headless-local@alice@bad.service"),
            None
        );
    }

    #[test]
    fn inventory_union_includes_loaded_instances_missing_from_unit_files() {
        let unit_files = "tokrate-headless-local@alice.service enabled\ntokrate-headless-local@bob.service disabled\nother.service enabled\n";
        let loaded = "tokrate-headless-local@builder.service loaded active running Tokrate\ntokrate-headless-share@bob.service loaded inactive dead Tokrate\nother.service loaded active running Other\ntokrate-headless-local@missing.service not-found inactive dead Tokrate\n";
        let units = service_inventory_units(unit_files, loaded);
        assert_eq!(units.len(), 4);
        assert_eq!(
            units
                .get("tokrate-headless-local@alice.service")
                .map(|(mode, user)| (*mode, user.as_str())),
            Some(("local", "alice"))
        );
        assert_eq!(
            units
                .get("tokrate-headless-local@bob.service")
                .map(|(mode, user)| (*mode, user.as_str())),
            Some(("local", "bob"))
        );
        assert_eq!(
            units
                .get("tokrate-headless-local@builder.service")
                .map(|(mode, user)| (*mode, user.as_str())),
            Some(("local", "builder"))
        );
        assert_eq!(
            units
                .get("tokrate-headless-share@bob.service")
                .map(|(mode, user)| (*mode, user.as_str())),
            Some(("share", "bob"))
        );
    }

    #[test]
    fn update_must_preserve_enabled_and_stopped_service_states() {
        assert!(service_state_matches("enabled", true, "enabled", "active"));
        assert!(service_state_matches(
            "disabled", false, "disabled", "inactive"
        ));
        assert!(service_state_matches(
            "disabled", false, "disabled", "failed"
        ));
        assert!(!service_state_matches(
            "enabled", true, "disabled", "active"
        ));
        assert!(!service_state_matches(
            "disabled", false, "enabled", "inactive"
        ));
        assert!(!service_state_matches(
            "disabled", false, "disabled", "active"
        ));
        assert!(!service_state_matches(
            "enabled", true, "enabled", "inactive"
        ));
    }

    #[test]
    fn root_release_high_water_rejects_version_or_sequence_replay() {
        assert!(release_is_at_least(20, "0.1.29", 19, "0.1.28").unwrap());
        assert!(release_is_at_least(20, "0.1.28", 20, "0.1.28").unwrap());
        assert!(!release_is_at_least(18, "0.1.29", 19, "0.1.28").unwrap());
        assert!(!release_is_at_least(21, "0.1.27", 19, "0.1.28").unwrap());
        assert!(!release_is_at_least(20, "0.1.29", 20, "0.1.28").unwrap());
    }

    #[test]
    fn rollback_package_tracks_both_update_check_units_when_present() {
        let rollback = rollback_unit_names(true, true).unwrap();
        assert!(rollback.contains(&UPDATE_CHECK_SERVICE));
        assert!(rollback.contains(&UPDATE_CHECK_TIMER));
        assert_eq!(rollback_unit_names(false, false).unwrap().len(), 2);
        assert!(rollback_unit_names(true, false).is_err());
        assert!(rollback_unit_names(false, true).is_err());
    }

    #[test]
    fn rollback_restores_timer_enablement_and_running_state_independently() {
        assert_eq!(
            timer_recovery_actions(TimerSnapshot {
                enabled: true,
                active: false,
            }),
            ("enable", "stop")
        );
        assert_eq!(
            timer_recovery_actions(TimerSnapshot {
                enabled: false,
                active: true,
            }),
            ("disable", "start")
        );
    }
}
