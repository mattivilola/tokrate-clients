mod config;
mod credentials;
mod dashboard;
mod runtime;
mod runtime_status;
mod source_config;
mod telemetry;
mod updater;
// These modules have no Tauri dependency. Share the tested native watcher implementation and
// change coalescing rather than maintaining a second filesystem observation policy.
#[allow(dead_code, clippy::unnecessary_map_or)]
#[path = "../../../desktop/src-tauri/src/schedule.rs"]
mod schedule;
#[path = "../../../desktop/src-tauri/src/watcher.rs"]
#[allow(dead_code, clippy::unnecessary_map_or)]
mod watcher;

pub(crate) const APP_VERSION: &str = env!("CARGO_PKG_VERSION");

use config::{Paths, Result};
use std::path::PathBuf;

const HELP: &str = "Tokrate headless Linux client\n\
Usage: tokrate-headless [--config-dir DIR] [--data-dir DIR] COMMAND\n\
  setup [--share|--local-only]  Save source defaults; first setup asks about sharing\n\
  run [--share]                Monitor continuously (local-only unless --share)\n\
  scan                        One local-only poll for diagnostics\n\
  status                      Print local collection/upload status as JSON\n\
  status-monitor [--demo]      Live terminal dashboard (Q/Esc returns to shell)\n\
  check-update                Check signed update availability now\n\
  update-checks on|off         Control automatic update availability checks\n\
  update [--yes]               Install a signed update after confirmation\n\
  sharing-enabled             Exit 0 only with current sharing consent\n\
  example                     Show the allowlisted upload with fake values\n\
  provision-key --output PATH  Installer: encrypt a signing identity (root only)\n\
  --version                   Print version\n\
For boot-time operation use linux/headless/install.sh --user YOUR_AGENT_USER.\n\
Consent alone does not start reporting: the sharing service must also be selected.\n\
Update checks are independent of sharing; package installation is always explicit.\n";

#[tokio::main(flavor = "current_thread")]
async fn main() {
    if let Err(error) = execute().await {
        eprintln!("Tokrate: {error}");
        std::process::exit(1);
    }
}

async fn execute() -> Result<()> {
    let mut args = std::env::args().skip(1).peekable();
    if args.peek().is_none_or(|arg| arg == "--help" || arg == "-h") {
        print!("{HELP}");
        return Ok(());
    }
    if args.peek().is_some_and(|arg| arg == "--version") {
        println!("tokrate-headless {}", APP_VERSION);
        return Ok(());
    }
    if args.peek().is_some_and(|arg| arg == "example") {
        println!("{}", telemetry::example_request_json());
        return Ok(());
    }
    let mut config_override = None;
    let mut data_override = None;
    while let Some("--config-dir" | "--data-dir") = args.peek().map(String::as_str) {
        let option = args.next().unwrap();
        let value = PathBuf::from(args.next().ok_or("Directory option requires a path")?);
        if !value.is_absolute() {
            return Err("Directory options must be absolute".into());
        }
        if option == "--config-dir" {
            config_override = Some(value);
        } else {
            data_override = Some(value);
        }
    }
    let command = args.next().ok_or("A command is required; use --help")?;
    let rest: Vec<String> = args.collect();
    let machine_command = matches!(
        command.as_str(),
        "check-update" | "update-check" | "update-checks" | "update"
    );
    if machine_command && (config_override.is_some() || data_override.is_some()) {
        return Err(
            "Update commands do not accept configuration or data directory overrides.".into(),
        );
    }
    if machine_command {
        return match (
            command.as_str(),
            rest.iter()
                .map(String::as_str)
                .collect::<Vec<_>>()
                .as_slice(),
        ) {
            ("check-update", []) => updater::check_update().await,
            ("update-check", ["--service"]) => updater::run_check_service().await,
            ("update-checks", ["on"]) => updater::update_checks_command(true),
            ("update-checks", ["off"]) => updater::update_checks_command(false),
            ("update", []) => updater::update_command(None, false).await,
            ("update", ["--yes"]) => updater::update_command(None, true).await,
            ("update", ["--confirmed-version", version, "--yes"])
                if unsafe { libc::geteuid() } == 0 =>
            {
                updater::update_command(Some(version), true).await
            }
            _ => Err("Unknown update command or arguments; use --help".into()),
        };
    }
    let mut paths = Paths::defaults()?;
    if let Some(config) = config_override {
        paths.config = config;
    }
    if let Some(data) = data_override {
        paths.data = data;
    }
    match (
        command.as_str(),
        rest.iter()
            .map(String::as_str)
            .collect::<Vec<_>>()
            .as_slice(),
    ) {
        ("setup", []) => config::setup(&paths, None),
        ("setup", ["--share"]) => config::setup(&paths, Some(true)),
        ("setup", ["--local-only"]) => config::setup(&paths, Some(false)),
        ("run", []) => {
            first_run(&paths)?;
            runtime::run(paths, false, false).await
        }
        ("run", ["--share"]) => {
            first_run(&paths)?;
            runtime::run(paths, true, false).await
        }
        ("scan", []) => runtime::run(paths, false, true).await,
        ("status", []) => runtime::status(&paths),
        ("status-monitor", []) => {
            if dashboard::monitor(&paths, false, false).await? {
                updater::update_command(None, false).await
            } else {
                Ok(())
            }
        }
        ("status-monitor", ["--demo"]) => dashboard::monitor(&paths, true, false).await.map(|_| ()),
        ("status-monitor", ["--demo", "--once"]) => {
            dashboard::monitor(&paths, true, true).await.map(|_| ())
        }
        ("sharing-enabled", []) => {
            if paths.consent_valid() {
                Ok(())
            } else {
                std::process::exit(1)
            }
        }
        ("example", []) => {
            println!("{}", telemetry::example_request_json());
            Ok(())
        }
        ("provision-key", ["--output", output]) => {
            credentials::provision(&paths, &PathBuf::from(output))
        }
        _ => Err("Unknown command or arguments; use --help".into()),
    }
}

fn first_run(paths: &Paths) -> Result<()> {
    if !paths.config.join("setup-complete").try_exists()? {
        config::setup(paths, None)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests;
