//! When the monitor polls: after the deadline the sources report, at the idle cadence, or as soon as
//! a folder watcher or a settings change asks for it, and never closer together than the minimum
//! spacing. The same rules as the Mac app (`HistoryStore.pollDelay`, `PollWaker`).
use chrono::{DateTime, Duration as Span, Utc};
use std::{sync::Mutex, time::Duration};
use tokio::sync::Notify;
use tokrate_core::SourceChange;

/// Polls are never closer together than this, whatever woke them.
pub const MIN_POLL_SPACING: Duration = Duration::from_secs(2);
/// The longest the monitor sleeps with nothing pending. A poll also ages the live value and moves
/// the Auto model selection, which must not stall while the folders are quiet.
pub const IDLE_POLL_INTERVAL: Duration = Duration::from_secs(30);
/// More changed paths than this are dropped in favour of a request to rescan.
pub const MAX_PENDING_PATHS: usize = 4_096;

fn span(duration: Duration) -> Span {
    Span::from_std(duration).unwrap_or(Span::MAX)
}

/// How long to wait after the poll that ended at `last_poll`: until `deadline` (the earliest
/// time-based transition the sources reported; `None` when nothing is pending), but no sooner than
/// the minimum spacing and no later than the idle interval. A clock that moved backwards cannot
/// stretch the wait past the idle interval.
pub fn poll_delay(
    now: DateTime<Utc>,
    last_poll: DateTime<Utc>,
    deadline: Option<DateTime<Utc>>,
) -> Duration {
    let idle = last_poll + span(IDLE_POLL_INTERVAL);
    let due = deadline.map_or(idle, |deadline| deadline.min(idle));
    let earliest = last_poll + span(MIN_POLL_SPACING);
    (due.max(earliest) - now)
        .to_std()
        .unwrap_or(Duration::ZERO)
        .min(IDLE_POLL_INTERVAL)
}

/// What ended a wait.
#[derive(Debug, Eq, PartialEq)]
pub enum Woken {
    /// The delay ran out.
    Due,
    /// Something reported a change or asked for a poll.
    Signalled,
}

/// What was reported since the previous [`PollSignal::take`].
#[derive(Debug, Default)]
pub struct Wake {
    /// What the folder watchers saw.
    pub change: SourceChange,
    /// A poll was asked for without a change to a source folder (a setting changed).
    pub requested: bool,
}

/// Wakes the polling task from the folder watchers and from settings changes.
///
/// A signal that arrives while a poll is running is kept (`Notify::notify_one` stores one permit),
/// so the next wait ends at once; a wait that timed out leaves later signals intact. Reports are
/// merged into one pending [`Wake`], so a watcher thread only ever takes a short lock and never
/// waits for a poll.
#[derive(Default)]
pub struct PollSignal {
    wake: Notify,
    pending: Mutex<Wake>,
}

impl PollSignal {
    /// Adds what a watcher saw. The poll task applies it to the monitors before it polls.
    pub fn report(&self, change: SourceChange) {
        {
            let mut pending = self.pending.lock().unwrap();
            pending.change.must_rescan |= change.must_rescan;
            pending.change.paths.extend(change.paths);
            if pending.change.paths.len() > MAX_PENDING_PATHS {
                pending.change = SourceChange {
                    must_rescan: true,
                    ..SourceChange::default()
                };
            }
        }
        self.wake.notify_one();
    }

    /// Asks for a poll without a source change: the tray, the watchers or the monitor's
    /// availability depend on a setting that just changed.
    pub fn request(&self) {
        self.pending.lock().unwrap().requested = true;
        self.wake.notify_one();
    }

    /// Takes everything reported so far.
    pub fn take(&self) -> Wake {
        std::mem::take(&mut *self.pending.lock().unwrap())
    }

    /// Waits for `delay` or for a signal, whichever comes first.
    pub async fn wait(&self, delay: Duration) -> Woken {
        tokio::select! {
            _ = tokio::time::sleep(delay) => Woken::Due,
            _ = self.wake.notified() => Woken::Signalled,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{path::PathBuf, sync::Arc, time::Instant};

    fn at(seconds: i64) -> DateTime<Utc> {
        DateTime::<Utc>::from_timestamp(1_800_000_000 + seconds, 0).unwrap()
    }
    fn delay(now: i64, last: i64, deadline: Option<i64>) -> Duration {
        poll_delay(at(now), at(last), deadline.map(at))
    }
    fn change(path: &str) -> SourceChange {
        SourceChange {
            paths: [PathBuf::from(path)].into(),
            must_rescan: false,
        }
    }

    #[test]
    fn idle_sources_wait_for_the_idle_interval() {
        assert_eq!(delay(100, 100, None), Duration::from_secs(30));
        assert_eq!(delay(110, 100, None), Duration::from_secs(20));
        assert_eq!(delay(131, 100, None), Duration::ZERO);
    }

    #[test]
    fn a_due_deadline_still_observes_the_minimum_spacing() {
        // Data left to read ("poll now") is a poll every two seconds, not a busy loop.
        assert_eq!(delay(100, 100, Some(100)), Duration::from_secs(2));
        assert_eq!(delay(101, 100, Some(100)), Duration::from_secs(1));
        assert_eq!(delay(105, 100, Some(90)), Duration::ZERO);
    }

    #[test]
    fn a_later_deadline_is_waited_for() {
        assert_eq!(delay(100, 100, Some(112)), Duration::from_secs(12));
        assert_eq!(delay(105, 100, Some(112)), Duration::from_secs(7));
    }

    #[test]
    fn the_idle_interval_caps_a_distant_deadline() {
        assert_eq!(delay(100, 100, Some(1_000)), Duration::from_secs(30));
        assert_eq!(delay(100, 100, Some(130)), Duration::from_secs(30));
    }

    #[test]
    fn a_wake_polls_at_the_minimum_spacing_after_the_last_poll() {
        // The poll task asks for a delay with a deadline of "now" after a watcher wake.
        let wake = |now: i64, last: i64| delay(now, last, Some(now));
        assert_eq!(wake(100, 100), Duration::from_secs(2));
        assert_eq!(wake(101, 100), Duration::from_secs(1));
        assert_eq!(wake(120, 100), Duration::ZERO);
    }

    #[test]
    fn a_clock_that_moved_backwards_cannot_stretch_the_wait() {
        assert_eq!(delay(0, 3_600, None), Duration::from_secs(30));
        assert_eq!(delay(0, 3_600, Some(3_700)), Duration::from_secs(30));
    }

    #[tokio::test]
    async fn a_signal_between_polls_is_not_lost() {
        let signal = PollSignal::default();
        signal.report(change("/root/a.jsonl"));
        let started = Instant::now();
        assert_eq!(signal.wait(Duration::from_secs(30)).await, Woken::Signalled);
        assert!(started.elapsed() < Duration::from_secs(5));
        assert_eq!(signal.take().change, change("/root/a.jsonl"));
    }

    #[tokio::test]
    async fn a_timeout_does_not_break_later_wakes() {
        let signal = Arc::new(PollSignal::default());
        assert_eq!(signal.wait(Duration::from_millis(20)).await, Woken::Due);
        // A wake that arrives after a timed-out wait, with no waiter, is kept for the next wait.
        signal.request();
        assert_eq!(signal.wait(Duration::from_secs(30)).await, Woken::Signalled);
        assert!(signal.take().requested);
        // And one that arrives while a wait is running ends it.
        let waiting = {
            let signal = signal.clone();
            tokio::spawn(async move { signal.wait(Duration::from_secs(30)).await })
        };
        tokio::time::sleep(Duration::from_millis(20)).await;
        signal.report(SourceChange {
            must_rescan: true,
            ..SourceChange::default()
        });
        assert_eq!(waiting.await.unwrap(), Woken::Signalled);
        assert!(signal.take().change.must_rescan);
    }

    #[tokio::test]
    async fn reports_are_merged_and_taken_once() {
        let signal = PollSignal::default();
        signal.report(change("/root/a.jsonl"));
        signal.report(change("/root/b.jsonl"));
        let wake = signal.take();
        assert_eq!(wake.change.paths.len(), 2);
        assert!(!wake.change.must_rescan && !wake.requested);
        let empty = signal.take();
        assert!(empty.change.paths.is_empty() && !empty.requested);
    }

    #[test]
    fn too_many_paths_become_a_rescan_request() {
        let signal = PollSignal::default();
        for chunk in 0..3 {
            signal.report(SourceChange {
                paths: (0..2_000)
                    .map(|index| PathBuf::from(format!("/root/{chunk}-{index}.jsonl")))
                    .collect(),
                must_rescan: false,
            });
        }
        let wake = signal.take();
        assert!(wake.change.must_rescan);
        assert!(wake.change.paths.is_empty());
    }
}
