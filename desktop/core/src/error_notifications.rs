//! When a community error alert becomes an operating-system notification (contract "Error
//! notifications (0.1.24)"). Pure: the host feeds it the relevant alerts of every new board and
//! posts what it returns.

use crate::error_alerts::RelevantErrorAlert;
use chrono::{DateTime, Duration, Utc};
use std::collections::{BTreeMap, VecDeque};

/// A model must be absent from the alerts this long before its episode ends.
pub const RECOVERY_WINDOW_MINUTES: i64 = 30;
/// At most this many notifications are posted per hour, starts and recoveries together.
pub const MAX_NOTIFICATIONS_PER_HOUR: usize = 3;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ErrorNotificationKind {
    Start,
    Recovery,
}

/// One notification to post.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ErrorNotification {
    pub kind: ErrorNotificationKind,
    pub model: String,
    pub title: String,
    pub body: String,
}

impl ErrorNotification {
    fn start(alert: &RelevantErrorAlert) -> Self {
        let body = if alert.not_just_you {
            format!(
                "It’s not just you: {} other {} hit provider errors on this model in the last hour.",
                alert.others,
                plural(alert.others, "contributor", "contributors"),
            )
        } else {
            let counts = [
                (alert.overloaded > 0)
                    .then(|| format!("{} overloaded / at capacity", alert.overloaded)),
                (alert.server_error > 0).then(|| {
                    format!(
                        "{} {}",
                        alert.server_error,
                        plural(alert.server_error, "server error", "server errors")
                    )
                }),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" and ");
            format!(
                "{} Tokrate {} reported {counts} in the last hour.",
                alert.failing_contributors,
                plural(alert.failing_contributors, "contributor", "contributors"),
            )
        };
        Self {
            kind: ErrorNotificationKind::Start,
            model: alert.model.clone(),
            title: format!("Provider errors on {}", alert.model),
            body,
        }
    }

    fn recovery(model: &str) -> Self {
        Self {
            kind: ErrorNotificationKind::Recovery,
            model: model.to_owned(),
            title: format!("{model} looks healthy again"),
            body: "Contributors no longer report provider errors on this model.".into(),
        }
    }
}

fn plural(n: u64, one: &'static str, many: &'static str) -> &'static str {
    if n == 1 {
        one
    } else {
        many
    }
}

/// One run of alerts for a model.
#[derive(Debug)]
struct Episode {
    /// Its start was notified (or counted as notified when it was already there), so its end is
    /// notified too.
    notified: bool,
    /// When a board first lacked the model; `None` while it is alerting.
    absent_since: Option<DateTime<Utc>>,
}

/// Decides which notifications a sequence of boards causes. Memory only. A new planner, or one
/// after [`reset`](Self::reset), takes the alerts of the next board as already notified.
#[derive(Debug, Default)]
pub struct ErrorNotificationPlanner {
    baselined: bool,
    episodes: BTreeMap<String, Episode>,
    /// When the notifications of the last hour were posted.
    posted: VecDeque<DateTime<Utc>>,
}

impl ErrorNotificationPlanner {
    pub fn new() -> Self {
        Self::default()
    }

    /// Forgets the episodes and the baseline: sharing or the setting turned off. The times of the
    /// notifications already posted stay, so switching off and on cannot get around the hourly cap.
    pub fn reset(&mut self) {
        self.baselined = false;
        self.episodes.clear();
    }

    /// Takes in the relevant alerts of a new board and returns the notifications to post, in
    /// order. The first board after a start or [`reset`](Self::reset) posts nothing: its alerts
    /// count as notified. Afterwards a model's first alert starts an episode with a notification;
    /// an episode that a board lacked for 30 minutes ends with a notification when its start was
    /// notified. The cap suppresses a start together with its recovery.
    pub fn plan(
        &mut self,
        alerts: &[RelevantErrorAlert],
        now: DateTime<Utc>,
    ) -> Vec<ErrorNotification> {
        // One alert per model: the most relevant.
        let mut present: Vec<&RelevantErrorAlert> = Vec::new();
        for alert in alerts {
            if !present.iter().any(|seen| seen.model == alert.model) {
                present.push(alert);
            }
        }
        if !self.baselined {
            self.baselined = true;
            self.episodes = present
                .iter()
                .map(|alert| {
                    (
                        alert.model.clone(),
                        Episode {
                            notified: true,
                            absent_since: None,
                        },
                    )
                })
                .collect();
            return Vec::new();
        }
        let mut notifications = Vec::new();
        let window = Duration::minutes(RECOVERY_WINDOW_MINUTES);
        for alert in &present {
            // An episode that boards found absent for the whole window has ended unseen (boards
            // were missing, so its end is not announced): the alert starts a new one.
            let running = self.episodes.get_mut(&alert.model).filter(|episode| {
                episode
                    .absent_since
                    .is_none_or(|since| now - since < window)
            });
            match running {
                // The alert came back within the recovery window: the same episode goes on.
                Some(episode) => episode.absent_since = None,
                None => {
                    let notified = self.take_slot(now);
                    self.episodes.insert(
                        alert.model.clone(),
                        Episode {
                            notified,
                            absent_since: None,
                        },
                    );
                    if notified {
                        notifications.push(ErrorNotification::start(alert));
                    }
                }
            }
        }
        let mut ended = Vec::new();
        for (model, episode) in &mut self.episodes {
            if present.iter().any(|alert| &alert.model == model) {
                continue;
            }
            let since = *episode.absent_since.get_or_insert(now);
            if now - since >= window {
                ended.push((model.clone(), episode.notified));
            }
        }
        for (model, notified) in ended {
            self.episodes.remove(&model);
            if notified && self.take_slot(now) {
                notifications.push(ErrorNotification::recovery(&model));
            }
        }
        notifications
    }

    /// Uses one of the hour's notifications, if one is left.
    fn take_slot(&mut self, now: DateTime<Utc>) -> bool {
        self.posted.retain(|at| now - *at < Duration::hours(1));
        if self.posted.len() >= MAX_NOTIFICATIONS_PER_HOUR {
            return false;
        }
        self.posted.push_back(now);
        true
    }
}
