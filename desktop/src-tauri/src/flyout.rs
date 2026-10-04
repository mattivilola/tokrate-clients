//! Tray flyout behaviour: anchoring the main window near the tray icon, hiding it on blur and
//! opening the separate full-history window. Geometry is pure so it can be tested on any OS.
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::{Duration, Instant},
};
use tauri::{
    AppHandle, Manager, PhysicalPosition, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
};

pub const MAIN: &str = "main";
pub const HISTORY: &str = "history";
pub const TRAY_ID: &str = "tokrate";
const EDGE_MARGIN: i32 = 8;
const TRAY_GAP: i32 = 6;
/// A tray click right after blur-hide is the same click that took focus away: it toggles closed.
const REOPEN_GUARD: Duration = Duration::from_millis(350);

/// A rectangle in physical pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Area {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

fn clamp_axis(value: i32, low: i32, high: i32) -> i32 {
    // A window larger than the area keeps its leading edge visible.
    value.min(high).max(low)
}

/// Centres the window on the tray icon and puts it above (taskbar at the bottom) or below (menu
/// bar at the top) the icon, then keeps it inside the work area so it never covers the taskbar.
pub fn place_near_tray(tray: Area, window: (i32, i32), work: Area) -> (i32, i32) {
    let (width, height) = window;
    let tray_centre_y = tray.y + tray.height / 2;
    let work_centre_y = work.y + work.height / 2;
    let x = tray.x + tray.width / 2 - width / 2;
    let y = if tray_centre_y > work_centre_y {
        tray.y - height - TRAY_GAP
    } else {
        tray.y + tray.height + TRAY_GAP
    };
    (
        clamp_axis(
            x,
            work.x + EDGE_MARGIN,
            work.x + work.width - width - EDGE_MARGIN,
        ),
        clamp_axis(
            y,
            work.y + EDGE_MARGIN,
            work.y + work.height - height - EDGE_MARGIN,
        ),
    )
}

/// Used when no tray rectangle is known (menu entry, second launch, startup): the corner of the
/// work area nearest the usual notification area.
pub fn place_in_corner(window: (i32, i32), work: Area, top: bool) -> (i32, i32) {
    let (width, height) = window;
    let x = work.x + work.width - width - EDGE_MARGIN;
    let y = if top {
        work.y + EDGE_MARGIN
    } else {
        work.y + work.height - height - EDGE_MARGIN
    };
    (x.max(work.x + EDGE_MARGIN), y.max(work.y + EDGE_MARGIN))
}

#[derive(Default)]
pub struct FlyoutState {
    suppress_blur_hide: AtomicBool,
    last_blur_hide: Mutex<Option<Instant>>,
}

impl FlyoutState {
    /// A native dialog (folder picker) takes focus from the flyout without meaning "dismiss".
    pub fn suppress_blur_hide(&self, on: bool) {
        self.suppress_blur_hide.store(on, Ordering::SeqCst);
    }
    fn blur_hide_suppressed(&self) -> bool {
        self.suppress_blur_hide.load(Ordering::SeqCst)
    }
    fn note_blur_hide(&self) {
        *self.last_blur_hide.lock().unwrap() = Some(Instant::now());
    }
    fn hidden_by_blur_just_now(&self) -> bool {
        self.last_blur_hide
            .lock()
            .unwrap()
            .is_some_and(|at| at.elapsed() < REOPEN_GUARD)
    }
}

/// The flyout behaviour needs a tray the user can reach. Linux keeps a normal, decorated window:
/// whether an indicator host exists cannot be detected reliably, and a window that hides on blur
/// without a visible tray icon would be unreachable.
pub fn is_flyout_mode(app: &AppHandle) -> bool {
    cfg!(not(target_os = "linux")) && app.tray_by_id(TRAY_ID).is_some()
}

fn place(window: &WebviewWindow, anchor: Option<Area>) {
    let Ok(size) = window.outer_size() else {
        return;
    };
    let app = window.app_handle();
    let monitor = anchor
        .and_then(|a| {
            app.monitor_from_point(f64::from(a.x + a.width / 2), f64::from(a.y + a.height / 2))
                .ok()
                .flatten()
        })
        .or_else(|| app.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else {
        return;
    };
    let work_area = monitor.work_area();
    let work = Area {
        x: work_area.position.x,
        y: work_area.position.y,
        width: i32::try_from(work_area.size.width).unwrap_or(i32::MAX),
        height: i32::try_from(work_area.size.height).unwrap_or(i32::MAX),
    };
    let window_size = (
        i32::try_from(size.width).unwrap_or(i32::MAX),
        i32::try_from(size.height).unwrap_or(i32::MAX),
    );
    let (x, y) = match anchor {
        Some(tray) => place_near_tray(tray, window_size, work),
        None => place_in_corner(window_size, work, cfg!(target_os = "macos")),
    };
    let _ = window.set_position(PhysicalPosition::new(x, y));
}

/// Shows and focuses the flyout, anchored to the tray icon when its rectangle is known.
pub fn show(app: &AppHandle, anchor: Option<Area>) {
    let Some(window) = app.get_webview_window(MAIN) else {
        return;
    };
    if is_flyout_mode(app) {
        place(&window, anchor);
    }
    let _ = window.show();
    let _ = window.unminimize();
    let _ = window.set_focus();
}

/// Hides the flyout; on Linux the window is minimised so it can always be restored.
pub fn hide(app: &AppHandle) {
    let Some(window) = app.get_webview_window(MAIN) else {
        return;
    };
    #[cfg(target_os = "linux")]
    let _ = window.minimize();
    #[cfg(not(target_os = "linux"))]
    let _ = window.hide();
}

/// Left click on the tray icon: toggle the flyout.
pub fn toggle_from_tray(app: &AppHandle, anchor: Area) {
    let Some(window) = app.get_webview_window(MAIN) else {
        return;
    };
    let state = app.state::<FlyoutState>();
    if state.hidden_by_blur_just_now() {
        return;
    }
    if is_flyout_mode(app)
        && window.is_visible().unwrap_or(false)
        && window.is_focused().unwrap_or(false)
    {
        hide(app);
    } else {
        show(app, Some(anchor));
    }
}

/// Focus left the flyout: hide it, unless that would lose something the user must still answer
/// (the first-run choice) or a native dialog opened from the flyout holds focus.
pub fn hide_on_blur(app: &AppHandle, consent_pending: bool, smoke: bool) {
    let state = app.state::<FlyoutState>();
    if smoke || consent_pending || !is_flyout_mode(app) || state.blur_hide_suppressed() {
        return;
    }
    state.note_blur_hide();
    hide(app);
}

/// Opens (or raises) the separate full-history window.
pub async fn open_history(app: AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(HISTORY) {
        let _ = window.show();
        let _ = window.unminimize();
        window.set_focus().map_err(|_| "Could not show history")?;
        return Ok(());
    }
    WebviewWindowBuilder::new(&app, HISTORY, WebviewUrl::App("index.html".into()))
        .title("Tokrate history")
        .inner_size(960.0, 720.0)
        .min_inner_size(640.0, 480.0)
        .center()
        .build()
        .map(|_| ())
        .map_err(|_| "Could not open history".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORK: Area = Area {
        x: 0,
        y: 0,
        width: 1920,
        height: 1040,
    };
    const WINDOW: (i32, i32) = (380, 640);

    #[test]
    fn bottom_taskbar_puts_the_flyout_above_the_icon_centred() {
        let tray = Area {
            x: 1700,
            y: 1040,
            width: 24,
            height: 40,
        };
        let (x, y) = place_near_tray(tray, WINDOW, WORK);
        assert_eq!(x, 1700 + 12 - 190);
        // The icon sits in the taskbar, below the work area: the flyout rests on the work area's edge.
        assert_eq!(y, 1040 - 640 - EDGE_MARGIN);
    }

    #[test]
    fn top_menu_bar_puts_the_flyout_below_the_icon() {
        let work = Area {
            x: 0,
            y: 0,
            width: 1440,
            height: 900,
        };
        let tray = Area {
            x: 1000,
            y: 0,
            width: 24,
            height: 24,
        };
        let (_, y) = place_near_tray(tray, WINDOW, work);
        assert_eq!(y, 24 + TRAY_GAP);
    }

    #[test]
    fn icon_at_the_right_edge_keeps_the_flyout_inside_the_work_area() {
        let tray = Area {
            x: 1900,
            y: 1040,
            width: 20,
            height: 40,
        };
        let (x, _) = place_near_tray(tray, WINDOW, WORK);
        assert_eq!(x, 1920 - 380 - EDGE_MARGIN);
        let tray = Area {
            x: 0,
            y: 1040,
            width: 20,
            height: 40,
        };
        let (x, _) = place_near_tray(tray, WINDOW, WORK);
        assert_eq!(x, EDGE_MARGIN);
    }

    #[test]
    fn vertical_taskbar_never_covers_the_taskbar() {
        // Taskbar on the right: work area is narrower than the monitor.
        let work = Area {
            x: 0,
            y: 0,
            width: 1860,
            height: 1080,
        };
        let tray = Area {
            x: 1880,
            y: 900,
            width: 40,
            height: 24,
        };
        let (x, y) = place_near_tray(tray, WINDOW, work);
        assert!(x + WINDOW.0 <= work.x + work.width - EDGE_MARGIN);
        assert!(y >= EDGE_MARGIN && y + WINDOW.1 <= work.height - EDGE_MARGIN);
    }

    #[test]
    fn a_window_taller_than_the_work_area_keeps_its_top_visible() {
        let small = Area {
            x: 0,
            y: 0,
            width: 1280,
            height: 600,
        };
        let tray = Area {
            x: 1200,
            y: 600,
            width: 24,
            height: 40,
        };
        let (_, y) = place_near_tray(tray, WINDOW, small);
        assert_eq!(y, EDGE_MARGIN);
    }

    #[test]
    fn corner_placement_uses_the_work_area() {
        let work = Area {
            x: 100,
            y: 50,
            width: 1000,
            height: 700,
        };
        assert_eq!(
            place_in_corner(WINDOW, work, false),
            (100 + 1000 - 380 - EDGE_MARGIN, 50 + 700 - 640 - EDGE_MARGIN)
        );
        assert_eq!(
            place_in_corner(WINDOW, work, true),
            (100 + 1000 - 380 - EDGE_MARGIN, 50 + EDGE_MARGIN)
        );
    }

    #[test]
    fn a_click_that_just_hid_the_flyout_does_not_reopen_it() {
        let state = FlyoutState::default();
        assert!(!state.hidden_by_blur_just_now());
        state.note_blur_hide();
        assert!(state.hidden_by_blur_just_now());
        state.suppress_blur_hide(true);
        assert!(state.blur_hide_suppressed());
        state.suppress_blur_hide(false);
        assert!(!state.blur_hide_suppressed());
    }
}
