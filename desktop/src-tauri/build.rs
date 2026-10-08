use std::{fs, path::Path};

/// The application commands the bundled UI invokes (`generate_handler!` in `src/main.rs`). Only
/// these are permitted: each needs its own `allow-<command>` permission in
/// `capabilities/default.json`, and a unit test keeps the three lists identical.
const COMMANDS: &[&str] = &[
    "snapshot",
    "update_settings",
    "record_sharing_consent",
    "set_dashboard_filters",
    "retry_sharing",
    "sent_example",
    "update_preferences",
    "set_automatic_update_checks",
    "check_update",
    "check_update_automatically",
    "install_update",
    "restart_after_update",
    "choose_folder",
    "reset_folder",
    "open_history",
    "hide_flyout",
    "open_website",
    "smoke_complete",
    "quit",
];

fn main() {
    let key_path = Path::new("../updater-public-key.txt");
    println!("cargo:rerun-if-changed={}", key_path.display());
    let key = fs::read_to_string(key_path)
        .expect("desktop updater public key is required")
        .trim()
        .to_owned();
    assert!(!key.is_empty(), "desktop updater public key is empty");
    let config = fs::read_to_string("tauri.conf.json").expect("Tauri config is required");
    assert!(
        config.contains(&format!("\"pubkey\": \"{key}\"")),
        "Tauri updater public key must match desktop/updater-public-key.txt"
    );
    assert!(
        config.contains("https://tokrate.dev/updates/desktop/alpha.json"),
        "Tauri updater endpoint must remain the fixed alpha feed"
    );
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(COMMANDS)),
    )
    .expect("failed to run the Tauri build script")
}
