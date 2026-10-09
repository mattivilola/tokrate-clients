#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod badge;
mod board;
mod flyout;
mod runtime;
mod schedule;
#[cfg(test)]
mod test_support;
mod updater_state;
mod watcher;
use flyout::{Area, FlyoutState};
use runtime::{Runtime, SettingsPatch, Snapshot};
use serde::Serialize;
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};
use tauri::{
    ipc::Channel,
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager, State,
};
use tauri_plugin_updater::UpdaterExt;
use updater_state::{UpdatePreferencesSnapshot, UpdateState, UpdateSummary};
type Shared = Arc<Mutex<Runtime>>;
type UpdateShared = Arc<Mutex<UpdateState>>;
#[tauri::command]
fn snapshot(state: State<Shared>, since_revision: Option<u64>) -> Snapshot {
    state.lock().unwrap().snapshot(since_revision)
}
#[tauri::command]
fn update_settings(state: State<Shared>, patch: SettingsPatch) -> Result<Snapshot, String> {
    let mut s = state.lock().unwrap();
    s.update(patch)?;
    Ok(s.snapshot(None))
}
#[tauri::command]
fn record_sharing_consent(
    app: tauri::AppHandle,
    state: State<Shared>,
    accepted: bool,
    notice_version: String,
) -> Result<Snapshot, String> {
    {
        let mut s = state.lock().unwrap();
        s.record_sharing_consent(accepted, &notice_version)?;
    }
    if accepted {
        runtime::restart_sharing(&app);
    }
    Ok(state.lock().unwrap().snapshot(None))
}
/// The flyout's coding-tool and provider filters ("all" or an id), which the tray value follows.
#[tauri::command]
fn set_dashboard_filters(
    state: State<Shared>,
    tool: String,
    provider: String,
) -> Result<(), String> {
    state
        .lock()
        .unwrap()
        .set_dashboard_filters(&tool, &provider)
}
/// The "See exactly what is sent" example, produced by the serializer that builds real requests.
#[tauri::command]
fn sent_example() -> String {
    tokrate_core::example_request_json()
}
#[tauri::command]
fn retry_sharing(app: tauri::AppHandle, state: State<Shared>) -> Snapshot {
    runtime::restart_sharing(&app);
    state.lock().unwrap().snapshot(None)
}
#[tauri::command]
fn update_preferences(state: State<UpdateShared>) -> UpdatePreferencesSnapshot {
    state.lock().unwrap().snapshot()
}
#[tauri::command]
fn set_automatic_update_checks(
    state: State<UpdateShared>,
    enabled: bool,
) -> Result<UpdatePreferencesSnapshot, String> {
    state.lock().unwrap().set_automatic_checks(enabled)
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UpdateCheckResult {
    started: bool,
    update: Option<UpdateSummary>,
}
async fn perform_update_check(
    app: tauri::AppHandle,
    state: State<'_, UpdateShared>,
    automatic: bool,
) -> Result<UpdateCheckResult, String> {
    let started = {
        let mut state = state.lock().unwrap();
        state.begin_check(automatic, chrono::Utc::now().timestamp())?
    };
    if !started {
        return Ok(UpdateCheckResult {
            started: false,
            update: None,
        });
    }
    let result = async {
        let update = app
            .updater_builder()
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|_| "Updater configuration is unavailable")?
            .check()
            .await
            .map_err(|_| "Could not check for updates")?;
        let update = updater_state::trusted_update(update, |update| &update.download_url)?;
        Ok::<_, String>(state.lock().unwrap().store_pending_update(update))
    }
    .await;
    state.lock().unwrap().finish_check();
    Ok(UpdateCheckResult {
        started: true,
        update: result?,
    })
}
#[tauri::command]
async fn check_update(
    app: tauri::AppHandle,
    state: State<'_, UpdateShared>,
) -> Result<UpdateCheckResult, String> {
    perform_update_check(app, state, false).await
}
#[tauri::command]
async fn check_update_automatically(
    app: tauri::AppHandle,
    state: State<'_, UpdateShared>,
) -> Result<UpdateCheckResult, String> {
    perform_update_check(app, state, true).await
}
#[derive(Clone, Serialize)]
#[serde(tag = "event", content = "data")]
enum UpdateDownloadEvent {
    Started { content_length: Option<u64> },
    Progress { chunk_length: usize },
    Finished,
}
#[tauri::command]
async fn install_update(
    state: State<'_, UpdateShared>,
    on_event: Channel<UpdateDownloadEvent>,
) -> Result<(), String> {
    let update = {
        let mut state = state.lock().unwrap();
        if !state.can_use_native_updater() {
            return Err("Updater installation is unavailable for this installation".into());
        }
        state
            .take_pending_update()
            .ok_or_else(|| "Check for an update before installing".to_owned())?
    };
    // Checked again where the download starts, whatever stored the update.
    if !updater_state::download_url_is_trusted(&update.download_url) {
        return Err("The update is not offered from Tokrate's release location".into());
    }
    let chunk_events = on_event.clone();
    let mut started = false;
    let result = update
        .download_and_install(
            move |chunk_length, content_length| {
                if !started {
                    let _ = chunk_events.send(UpdateDownloadEvent::Started { content_length });
                    started = true;
                }
                let _ = chunk_events.send(UpdateDownloadEvent::Progress { chunk_length });
            },
            move || {
                let _ = on_event.send(UpdateDownloadEvent::Finished);
            },
        )
        .await;
    if result.is_err() {
        state.lock().unwrap().store_pending_update(Some(update));
        return Err("The signed update could not be verified or installed".into());
    }
    Ok(())
}
/// Writes the local history and its checkpoints before the app goes away, so the files read since
/// the last write are not read again at the next launch.
fn save_history_on_exit(app: &tauri::AppHandle) {
    if let Some(runtime) = app.try_state::<Shared>() {
        if let Ok(mut runtime) = runtime.lock() {
            runtime.save_on_exit();
        }
    }
}
#[tauri::command]
fn restart_after_update(app: tauri::AppHandle) {
    // A restart ends the process without the exit event.
    save_history_on_exit(&app);
    app.restart();
}
#[tauri::command]
async fn choose_folder(app: tauri::AppHandle, source: String) -> Result<Snapshot, String> {
    let title = match source.as_str() {
        "codex" => "Choose Codex sessions folder",
        "claude-code" => "Choose Claude Code projects folder",
        "grok-build" => "Choose Grok Build sessions folder",
        "antigravity" => "Choose Antigravity data folder",
        "opencode" => "Choose OpenCode data folder",
        "kimi-code" => "Choose Kimi Code folder",
        _ => return Err("Choose a supported source".into()),
    };
    // The native dialog takes focus from the flyout; that must not dismiss it.
    let flyout = app.state::<FlyoutState>();
    flyout.suppress_blur_hide(true);
    let folder = rfd::AsyncFileDialog::new()
        .set_title(title)
        .pick_folder()
        .await;
    flyout.suppress_blur_hide(false);
    let state = app.state::<Shared>();
    if let Some(folder) = folder {
        state
            .lock()
            .unwrap()
            .set_source_root(&source, folder.path().to_path_buf())?;
    }
    let result = state.lock().unwrap().snapshot(None);
    Ok(result)
}
#[tauri::command]
fn reset_folder(app: tauri::AppHandle, source: String) -> Result<Snapshot, String> {
    let state = app.state::<Shared>();
    let mut runtime = state.lock().unwrap();
    runtime.reset_source_root(&source)?;
    Ok(runtime.snapshot(None))
}
#[tauri::command]
async fn open_history(app: tauri::AppHandle) -> Result<(), String> {
    flyout::open_history(app).await
}
#[tauri::command]
fn hide_flyout(app: tauri::AppHandle) {
    if flyout::is_flyout_mode(&app) {
        flyout::hide(&app);
    }
}
#[tauri::command]
fn open_website(page: String) -> Result<(), String> {
    let url = match page.as_str() {
        "home" => "https://tokrate.dev",
        "privacy" => "https://tokrate.dev/privacy",
        "terms" => "https://tokrate.dev/terms",
        "desktop-downloads" => "https://tokrate.dev/download",
        _ => return Err("Unsupported page".into()),
    };
    open::that(url).map_err(|_| "Could not open your browser".into())
}
#[tauri::command]
fn smoke_complete(
    app: tauri::AppHandle,
    state: State<Shared>,
    updates: State<UpdateShared>,
) -> Result<(), String> {
    state.lock().unwrap().finish_smoke()?;
    if !updates.lock().unwrap().smoke_network_disabled() {
        return Err("Smoke runs must keep updater networking disabled".into());
    }
    app.exit(0);
    Ok(())
}
#[tauri::command]
fn quit(app: tauri::AppHandle) {
    app.exit(0)
}
fn main() {
    let smoke = std::env::args().any(|a| a == "--smoke-test");
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            flyout::show(app, None)
        }))
        .manage(FlyoutState::default());
    let builder = if updater_state::updater_plugin_enabled(smoke) {
        builder.plugin(tauri_plugin_updater::Builder::new().build())
    } else {
        builder
    };
    builder
        .invoke_handler(tauri::generate_handler![
            snapshot,
            update_settings,
            record_sharing_consent,
            set_dashboard_filters,
            retry_sharing,
            sent_example,
            update_preferences,
            set_automatic_update_checks,
            check_update,
            check_update_automatically,
            install_update,
            restart_after_update,
            choose_folder,
            reset_folder,
            open_history,
            hide_flyout,
            open_website,
            smoke_complete,
            quit
        ])
        .setup(move |app| {
            let dir = app.path().app_local_data_dir()?;
            let runtime = if smoke {
                let dir =
                    std::env::var_os("TOKRATE_SMOKE_DIR").ok_or("Smoke directory required")?;
                Runtime::load_smoke(dir.into())?
            } else {
                Runtime::load(dir)?
            };
            app.manage(Arc::new(Mutex::new(runtime)));
            let update_dir = if smoke {
                std::env::var_os("TOKRATE_SMOKE_DIR")
                    .ok_or("Smoke directory required")?
                    .into()
            } else {
                app.path().app_local_data_dir()?
            };
            let updates = UpdateState::load(update_dir, smoke).map_err(std::io::Error::other)?;
            app.manage(Arc::new(Mutex::new(updates)));
            let dashboard =
                MenuItem::with_id(app, "dashboard", "Open dashboard", true, None::<&str>)?;
            let history = MenuItem::with_id(app, "history", "Full history", true, None::<&str>)?;
            let speed =
                MenuItem::with_id(app, "speed", "Waiting for a response", false, None::<&str>)?;
            let website =
                MenuItem::with_id(app, "website", "Open global stats", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Tokrate", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&dashboard, &history, &speed, &website, &quit])?;
            let tray = TrayIconBuilder::with_id("tokrate")
                .icon(badge::default_icon()?)
                .tooltip("Tokrate — Response speed")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "dashboard" => flyout::show(app, None),
                    "history" => {
                        let app = app.clone();
                        tauri::async_runtime::spawn(async move {
                            let _ = flyout::open_history(app).await;
                        });
                    }
                    "website" => {
                        let _ = open_website("home".into());
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        position,
                        rect,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        let scale = app
                            .monitor_from_point(position.x, position.y)
                            .ok()
                            .flatten()
                            .map_or(1.0, |monitor| monitor.scale_factor());
                        let origin = rect.position.to_physical::<i32>(scale);
                        let size = rect.size.to_physical::<i32>(scale);
                        flyout::toggle_from_tray(
                            app,
                            Area {
                                x: origin.x,
                                y: origin.y,
                                width: size.width,
                                height: size.height,
                            },
                        );
                    }
                })
                .build(app);
            // A visible dashboard remains usable on Linux desktops without an indicator host.
            if tray.is_err() {
                app.state::<Shared>().lock().unwrap().monitor_status =
                    "Tray unavailable on this desktop. Keep this dashboard open.".into();
            }
            // Windows and macOS: a compact, undecorated flyout that hides on blur. Linux and any
            // desktop without a tray keep an ordinary decorated window that is always reachable.
            let flyout_mode = flyout::is_flyout_mode(app.handle());
            if let Some(window) = app.get_webview_window(flyout::MAIN) {
                if flyout_mode {
                    let _ = window.set_skip_taskbar(true);
                } else {
                    let _ = window.set_decorations(true);
                    let _ = window.set_resizable(true);
                }
            }
            let (consent_pending, smoke_run) = {
                let runtime = app.state::<Shared>();
                let runtime = runtime.lock().unwrap();
                (runtime.consent_pending(), runtime.is_smoke())
            };
            // Stay in the tray at launch unless the user must answer the first-run choice.
            if smoke_run || consent_pending || !flyout_mode {
                flyout::show(app.handle(), None);
            }
            runtime::start_monitor(app.handle().clone(), speed);
            runtime::restart_sharing(app.handle());
            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() != flyout::MAIN {
                return;
            }
            match event {
                tauri::WindowEvent::CloseRequested { api, .. } => {
                    if window.app_handle().tray_by_id(flyout::TRAY_ID).is_some() {
                        api.prevent_close();
                        flyout::hide(window.app_handle());
                    }
                }
                tauri::WindowEvent::Focused(false) => {
                    let app = window.app_handle();
                    let (consent_pending, smoke) = {
                        let runtime = app.state::<Shared>();
                        let runtime = runtime.lock().unwrap();
                        (runtime.consent_pending(), runtime.is_smoke())
                    };
                    flyout::hide_on_blur(app, consent_pending, smoke);
                }
                _ => {}
            }
        })
        .build(tauri::generate_context!())
        .expect("Tokrate could not start")
        .run(|app, event| {
            if matches!(event, tauri::RunEvent::Exit) {
                save_history_on_exit(app);
            }
        });
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    /// The names listed between `open` and `close` in `source`, one per comma-separated entry.
    fn listed(source: &str, open: &str, close: &str) -> BTreeSet<String> {
        let start = source.find(open).expect("list start") + open.len();
        let end = start + source[start..].find(close).expect("list end");
        source[start..end]
            .split(',')
            .map(|name| name.trim().trim_matches('"').to_owned())
            .filter(|name| !name.is_empty())
            .collect()
    }

    #[test]
    fn only_the_commands_the_handler_serves_are_permitted_to_the_windows() {
        let handler = listed(include_str!("main.rs"), "generate_handler![", "])");
        let manifest = listed(include_str!("../build.rs"), "COMMANDS: &[&str] = &[", "];");
        assert!(handler.len() > 10);
        assert_eq!(handler, manifest, "build.rs COMMANDS and generate_handler!");

        let capability: serde_json::Value =
            serde_json::from_str(include_str!("../capabilities/default.json")).unwrap();
        let granted: BTreeSet<String> = capability["permissions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|permission| permission.as_str().unwrap().to_owned())
            .collect();
        let expected: BTreeSet<String> = handler
            .iter()
            .map(|command| format!("allow-{}", command.replace('_', "-")))
            .collect();
        // Nothing but the application's own commands: no `core:` or plugin permission.
        assert_eq!(granted, expected);
    }
}
