use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf};
use tauri::utils::platform;
use tauri_plugin_updater::Update;

const AUTOMATIC_CHECK_INTERVAL_SECONDS: i64 = 24 * 60 * 60;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum UpdateMode {
    Native,
    Manual,
    Unavailable,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SavedPreferences {
    #[serde(default = "default_automatic_checks")]
    automatic_checks: bool,
    last_check_unix_seconds: Option<i64>,
}

fn default_automatic_checks() -> bool {
    true
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdatePreferencesSnapshot {
    automatic_checks: bool,
    mode: UpdateMode,
    settings_warning: Option<String>,
    current_version: String,
}

pub struct UpdateState {
    path: PathBuf,
    automatic_checks: bool,
    last_check_unix_seconds: Option<i64>,
    warning: Option<String>,
    smoke: bool,
    mode: UpdateMode,
    check_in_flight: bool,
    pending_update: Option<Update>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateSummary {
    pub version: String,
    pub body: Option<String>,
}

impl UpdateState {
    pub fn load(dir: PathBuf, smoke: bool) -> Result<Self, String> {
        Self::load_with_mode(dir, smoke, runtime_mode())
    }

    fn load_with_mode(
        dir: PathBuf,
        smoke: bool,
        requested_mode: UpdateMode,
    ) -> Result<Self, String> {
        fs::create_dir_all(&dir).map_err(|_| "Could not prepare update preferences".to_owned())?;
        let path = dir.join("update-preferences.json");
        let (automatic_checks, last_check_unix_seconds, warning) = match fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice::<SavedPreferences>(&bytes) {
                Ok(saved) => (saved.automatic_checks, saved.last_check_unix_seconds, None),
                Err(_) => (
                    false,
                    None,
                    Some("Automatic update checks are paused because their preferences could not be read.".into()),
                ),
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (true, None, None),
            Err(_) => (
                false,
                None,
                Some("Automatic update checks are paused because their preferences could not be read.".into()),
            ),
        };
        Ok(Self {
            path,
            automatic_checks: automatic_checks && !smoke,
            last_check_unix_seconds,
            warning,
            smoke,
            mode: if smoke {
                UpdateMode::Unavailable
            } else {
                requested_mode
            },
            check_in_flight: false,
            pending_update: None,
        })
    }

    pub fn snapshot(&self) -> UpdatePreferencesSnapshot {
        UpdatePreferencesSnapshot {
            automatic_checks: self.automatic_checks,
            mode: self.mode,
            settings_warning: self.warning.clone(),
            current_version: env!("CARGO_PKG_VERSION").into(),
        }
    }

    pub fn set_automatic_checks(
        &mut self,
        enabled: bool,
    ) -> Result<UpdatePreferencesSnapshot, String> {
        if self.smoke && enabled {
            return Err("Smoke runs cannot enable update checks".into());
        }
        let next = SavedPreferences {
            automatic_checks: enabled,
            last_check_unix_seconds: self.last_check_unix_seconds,
        };
        self.save(&next)?;
        self.automatic_checks = enabled;
        self.warning = None;
        Ok(self.snapshot())
    }

    pub fn begin_check(&mut self, automatic: bool, now_unix_seconds: i64) -> Result<bool, String> {
        if self.smoke || self.mode != UpdateMode::Native {
            return Err("Updater checks are unavailable for this installation".into());
        }
        if self.check_in_flight {
            return Ok(false);
        }
        if automatic && !self.automatic_checks {
            return Ok(false);
        }
        if automatic
            && self.last_check_unix_seconds.is_some_and(|last| {
                now_unix_seconds >= last
                    && now_unix_seconds - last < AUTOMATIC_CHECK_INTERVAL_SECONDS
            })
        {
            return Ok(false);
        }

        let next = SavedPreferences {
            automatic_checks: self.automatic_checks,
            last_check_unix_seconds: Some(now_unix_seconds),
        };
        self.save(&next)?;
        self.last_check_unix_seconds = next.last_check_unix_seconds;
        self.check_in_flight = true;
        Ok(true)
    }

    pub fn finish_check(&mut self) {
        self.check_in_flight = false;
    }

    pub fn can_use_native_updater(&self) -> bool {
        !self.smoke && self.mode == UpdateMode::Native
    }

    pub fn store_pending_update(&mut self, update: Option<Update>) -> Option<UpdateSummary> {
        let summary = update.as_ref().map(|update| UpdateSummary {
            version: update.version.clone(),
            body: update.body.clone(),
        });
        self.pending_update = update;
        summary
    }

    pub fn take_pending_update(&mut self) -> Option<Update> {
        self.pending_update.take()
    }

    pub fn smoke_network_disabled(&self) -> bool {
        self.smoke && !self.automatic_checks && self.mode == UpdateMode::Unavailable
    }

    fn save(&self, saved: &SavedPreferences) -> Result<(), String> {
        let bytes =
            serde_json::to_vec_pretty(saved).map_err(|_| "Update preferences are invalid")?;
        tokrate_core::write_private_file(&self.path, &bytes)
            .map_err(|_| "Could not save update preferences".into())
    }
}

fn runtime_mode() -> UpdateMode {
    match platform::bundle_type() {
        #[cfg(windows)]
        Some(tauri::utils::config::BundleType::Nsis) => UpdateMode::Native,
        #[cfg(target_os = "linux")]
        Some(tauri::utils::config::BundleType::AppImage) => UpdateMode::Native,
        #[cfg(target_os = "linux")]
        Some(tauri::utils::config::BundleType::Deb) => UpdateMode::Manual,
        _ => UpdateMode::Unavailable,
    }
}

pub fn updater_plugin_enabled(smoke: bool) -> bool {
    !smoke && runtime_mode() == UpdateMode::Native
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temporary() -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("tokrate-updater-test-{}", rand::random::<u64>()));
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn defaults_on_and_persists_separately_from_sharing_preferences() {
        let dir = temporary();
        let sharing = b"sharing preference fixture";
        fs::write(dir.join("settings.json"), sharing).unwrap();
        let mut state =
            UpdateState::load_with_mode(dir.clone(), false, UpdateMode::Native).unwrap();
        assert!(state.snapshot().automatic_checks);
        state.set_automatic_checks(false).unwrap();
        assert!(
            !UpdateState::load_with_mode(dir.clone(), false, UpdateMode::Native)
                .unwrap()
                .snapshot()
                .automatic_checks
        );
        assert_eq!(fs::read(dir.join("settings.json")).unwrap(), sharing);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn valid_older_preferences_without_automatic_checks_default_on() {
        let dir = temporary();
        fs::write(
            dir.join("update-preferences.json"),
            br#"{"lastCheckUnixSeconds":null}"#,
        )
        .unwrap();
        let state = UpdateState::load_with_mode(dir.clone(), false, UpdateMode::Native).unwrap();
        assert!(state.snapshot().automatic_checks);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn automatic_checks_are_persistently_throttled_but_manual_checks_are_available() {
        let dir = temporary();
        let mut state =
            UpdateState::load_with_mode(dir.clone(), false, UpdateMode::Native).unwrap();
        assert!(state.begin_check(true, 1_000_000).unwrap());
        state.finish_check();
        assert!(!state.begin_check(true, 1_000_001).unwrap());
        assert!(state.begin_check(false, 1_000_001).unwrap());
        assert!(!state.begin_check(false, 1_000_002).unwrap());
        state.finish_check();
        assert!(state
            .begin_check(true, 1_000_001 + AUTOMATIC_CHECK_INTERVAL_SECONDS)
            .unwrap());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_clock_rollback_does_not_lock_automatic_checks() {
        let dir = temporary();
        let mut state =
            UpdateState::load_with_mode(dir.clone(), false, UpdateMode::Native).unwrap();
        assert!(state.begin_check(true, 2_000_000).unwrap());
        state.finish_check();
        assert!(state.begin_check(true, 1_000_000).unwrap());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn corrupt_preferences_pause_automatic_checks_and_smoke_never_allows_network() {
        let dir = temporary();
        fs::write(dir.join("update-preferences.json"), b"{broken").unwrap();
        let mut state =
            UpdateState::load_with_mode(dir.clone(), false, UpdateMode::Native).unwrap();
        assert!(!state.snapshot().automatic_checks);
        assert!(state.snapshot().settings_warning.is_some());
        assert!(!state.begin_check(true, 1_000_000).unwrap());
        assert!(state.begin_check(false, 1_000_000).unwrap());
        state.finish_check();

        let mut smoke = UpdateState::load_with_mode(dir.clone(), true, UpdateMode::Native).unwrap();
        assert!(!smoke.snapshot().automatic_checks);
        assert!(smoke.begin_check(false, 1_000_001).is_err());
        assert!(smoke.set_automatic_checks(true).is_err());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn deb_and_unknown_installers_do_not_use_the_privileged_native_updater() {
        let dir = temporary();
        for mode in [UpdateMode::Manual, UpdateMode::Unavailable] {
            let mut state = UpdateState::load_with_mode(dir.clone(), false, mode).unwrap();
            assert!(state.begin_check(false, 1_000_000).is_err());
        }
        fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn saved_preferences_are_readable_by_their_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temporary();
        let path = dir.join("update-preferences.json");
        fs::write(
            &path,
            br#"{"automaticChecks":true,"lastCheckUnixSeconds":null}"#,
        )
        .unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        let mut state =
            UpdateState::load_with_mode(dir.clone(), false, UpdateMode::Native).unwrap();
        state.set_automatic_checks(false).unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(dir).unwrap();
    }
}
