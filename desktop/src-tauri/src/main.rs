#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod runtime;
use runtime::{Runtime, SettingsPatch, Snapshot};
use std::sync::{Arc, Mutex};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager, State,
};
type Shared = Arc<Mutex<Runtime>>;
#[tauri::command]
fn snapshot(state: State<Shared>, since_revision: Option<u64>) -> Snapshot {
    state.lock().unwrap().snapshot(since_revision)
}
#[tauri::command]
fn update_settings(
    app: tauri::AppHandle,
    state: State<Shared>,
    patch: SettingsPatch,
) -> Result<Snapshot, String> {
    let restart = patch.sharing.is_some();
    {
        let mut s = state.lock().unwrap();
        s.update(patch)?;
    }
    if restart {
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
async fn choose_folder(app: tauri::AppHandle) -> Result<Snapshot, String> {
    let folder = rfd::AsyncFileDialog::new()
        .set_title("Choose Codex sessions folder")
        .pick_folder()
        .await;
    let state = app.state::<Shared>();
    if let Some(folder) = folder {
        state
            .lock()
            .unwrap()
            .set_root(folder.path().to_path_buf())?;
    }
    let result = state.lock().unwrap().snapshot(None);
    Ok(result)
}
#[tauri::command]
fn open_website(page: String) -> Result<(), String> {
    let url = match page.as_str() {
        "home" => "https://tokrate.dev",
        "privacy" => "https://tokrate.dev/privacy",
        _ => return Err("Unsupported page".into()),
    };
    open::that(url).map_err(|_| "Could not open your browser".into())
}
#[tauri::command]
fn smoke_complete(app: tauri::AppHandle, state: State<Shared>) -> Result<(), String> {
    state.lock().unwrap().finish_smoke()?;
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
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| show(app)))
        .invoke_handler(tauri::generate_handler![
            snapshot,
            update_settings,
            retry_sharing,
            choose_folder,
            open_website,
            smoke_complete,
            quit
        ])
        .setup(|app| {
            let dir = app.path().app_local_data_dir()?;
            let smoke = std::env::args().any(|a| a == "--smoke-test");
            let runtime = if smoke {
                let dir =
                    std::env::var_os("TOKRATE_SMOKE_DIR").ok_or("Smoke directory required")?;
                Runtime::load_smoke(dir.into())?
            } else {
                Runtime::load(dir)?
            };
            app.manage(Arc::new(Mutex::new(runtime)));
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
