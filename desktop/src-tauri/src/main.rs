#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod runtime;
mod updater_state;
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
#[tauri::command]
fn restart_after_update(app: tauri::AppHandle) {
    app.restart();
}
#[tauri::command]
async fn choose_folder(app: tauri::AppHandle, source: String) -> Result<Snapshot, String> {
    let title = match source.as_str() {
        "codex" => "Choose Codex sessions folder",
        "claude-code" => "Choose Claude Code projects folder",
        "grok-build" => "Choose Grok Build sessions folder",
        _ => return Err("Choose a supported source".into()),
    };
    let folder = rfd::AsyncFileDialog::new()
        .set_title(title)
        .pick_folder()
        .await;
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
fn show(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}
fn main() {
    let smoke = std::env::args().any(|a| a == "--smoke-test");
    let builder =
        tauri::Builder::default().plugin(tauri_plugin_single_instance::init(|app, _, _| show(app)));
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
            retry_sharing,
            update_preferences,
            set_automatic_update_checks,
            check_update,
            check_update_automatically,
            install_update,
            restart_after_update,
            choose_folder,
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
            let speed = MenuItem::with_id(
                app,
                "speed",
                "Waiting for a completed turn",
                false,
                None::<&str>,
            )?;
            let website =
                MenuItem::with_id(app, "website", "Open global stats", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit Tokrate", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&dashboard, &speed, &website, &quit])?;
            let tray = TrayIconBuilder::with_id("tokrate")
                .icon(tauri::image::Image::from_bytes(include_bytes!(
                    "../icons/icon.png"
                ))?)
                .tooltip("Tokrate — completed-turn throughput")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "dashboard" => show(app),
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
                        ..
                    } = event
                    {
                        show(tray.app_handle());
                    }
                })
                .build(app);
            // A visible dashboard remains usable on Linux desktops without an indicator host.
            if tray.is_err() {
                app.state::<Shared>().lock().unwrap().monitor_status =
                    "Tray unavailable on this desktop. Keep this dashboard open.".into();
            }
            runtime::start_monitor(app.handle().clone(), speed);
            runtime::restart_sharing(app.handle());
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.app_handle().tray_by_id("tokrate").is_some() {
                    api.prevent_close();
                    #[cfg(target_os = "linux")]
                    let _ = window.minimize();
                    #[cfg(not(target_os = "linux"))]
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("Tokrate could not start");
}
