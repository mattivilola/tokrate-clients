use std::{fs, path::Path};

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
    tauri_build::build()
}
