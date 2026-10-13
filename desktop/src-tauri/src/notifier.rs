//! Operating-system notifications about community error alerts. They are posted from here, in the
//! native runtime, from its own board data: the webview is granted no notification permission and
//! never sees or asks for one.
use crate::flyout;
use std::sync::Arc;
use tauri_plugin_notification::NotificationExt;
use tokrate_core::ErrorNotification;

/// Posts notifications to the operating system. A trait so the runtime's tests post to a mock.
pub trait Notifier: Send + Sync {
    fn post(&self, notification: &ErrorNotification);
}

/// Notifications a board caused, posted once the runtime lock is released so that a slow
/// notification service cannot hold it.
#[must_use]
pub struct Delivery {
    notifier: Arc<dyn Notifier>,
    notifications: Vec<ErrorNotification>,
}

impl Delivery {
    pub fn new(notifier: Arc<dyn Notifier>, notifications: Vec<ErrorNotification>) -> Self {
        Self {
            notifier,
            notifications,
        }
    }

    pub fn post(self) {
        for notification in &self.notifications {
            self.notifier.post(notification);
        }
    }
}

/// The operating system's notification service through the Tauri notification plugin.
struct SystemNotifier {
    app: tauri::AppHandle,
}

impl Notifier for SystemNotifier {
    fn post(&self, notification: &ErrorNotification) {
        // Nothing to do when the system declines (for example notifications turned off for Tokrate
        // in the system settings): the alert stays visible in the dashboard.
        let _ = self
            .app
            .notification()
            .builder()
            .title(&notification.title)
            .body(&notification.body)
            .show();
    }
}

/// Makes a click on a notification open the dashboard and returns the notifier that posts them.
///
/// The plugin reports a click (`tap`) on a notification of this run on Windows, macOS and Linux,
/// as far as the notification service reports it: on Windows only while the toast is on screen,
/// not once it moved to the Action Center, and on Linux only on servers that support the
/// `default` action. Notifications carry no other action.
pub fn install(app: &tauri::AppHandle) -> Arc<dyn Notifier> {
    let handle = app.clone();
    let _ = app.notification().on_action(move |action| {
        if action.action_id() == "tap" {
            flyout::show(&handle, None);
        }
    });
    Arc::new(SystemNotifier { app: app.clone() })
}
