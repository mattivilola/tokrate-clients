//! Folder watchers: one recursive watcher per existing source root reports what changed, so the
//! monitor opens only the files that did. The same shape as the Mac app's `SessionFolderWatcher`
//! and `HistoryStore.syncWatchers`.
use crate::schedule::{PollSignal, IDLE_POLL_INTERVAL, MAX_PENDING_PATHS};
use notify::{
    event::{CreateKind, ModifyKind},
    Config, Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher,
};
use std::{
    borrow::Cow,
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, RecvTimeoutError},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};
use tokrate_core::SourceChange;

/// Events of one burst are collected this long before they reach the poll task.
const COALESCE_WINDOW: Duration = Duration::from_millis(500);
/// Windows and macOS file systems are case-insensitive by default, and their watchers may spell a
/// path with the case it has on disk.
const FOLD_CASE: bool = cfg!(any(windows, target_os = "macos"));

/// A source whose folder is watched.
pub struct WatchTarget {
    pub source: &'static str,
    pub root: PathBuf,
    /// The folder exists now (the monitor's `root_exists`).
    pub exists: bool,
    /// Everything below the folder is watched; otherwise only its direct children, for a folder
    /// whose files lie directly in it next to large subfolders that change constantly.
    pub recursive: bool,
}

/// The path without a Windows verbatim prefix: `\\?\C:\x` is `C:\x`, `\\?\UNC\host\share` is
/// `\\host\share`.
fn without_verbatim_prefix(path: &str) -> Cow<'_, str> {
    if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
        Cow::Owned(format!(r"\\{rest}"))
    } else if let Some(rest) = path.strip_prefix(r"\\?\") {
        Cow::Borrowed(rest)
    } else {
        Cow::Borrowed(path)
    }
}

fn plain(path: &Path) -> PathBuf {
    if cfg!(windows) {
        PathBuf::from(without_verbatim_prefix(&path.to_string_lossy()).as_ref())
    } else {
        path.to_path_buf()
    }
}

/// What remains of `path` below `root`, comparing components (ignoring ASCII case with `fold`).
fn strip_root(path: &Path, root: &Path, fold: bool) -> Option<PathBuf> {
    let mut rest = path.components();
    for wanted in root.components() {
        let found = rest.next()?;
        let same = if fold {
            found.as_os_str().eq_ignore_ascii_case(wanted.as_os_str())
        } else {
            found == wanted
        };
        if !same {
            return None;
        }
    }
    Some(rest.as_path().to_path_buf())
}

/// Where an event path lies relative to the watched root.
#[derive(Debug, Eq, PartialEq)]
enum Placement {
    /// The root itself.
    Root,
    /// Below the root, spelled under the configured root.
    Below(PathBuf),
    /// Not below the root in any spelling the mapper knows.
    Elsewhere,
}

/// Re-spells event paths under the root exactly as the monitor was created with it. A watcher can
/// report a canonical spelling instead (a symlinked root, `/private/var` for `/var` on macOS, a
/// Windows `\\?\` prefix, the on-disk case), which the monitors would not recognize.
#[derive(Clone, Debug)]
struct RootMapper {
    configured: PathBuf,
    /// The spellings a watcher may use for the root: as configured, and fully resolved.
    spellings: Vec<PathBuf>,
    fold: bool,
}

impl RootMapper {
    fn new(root: &Path) -> Self {
        Self::with_case_folding(root, FOLD_CASE)
    }

    fn with_case_folding(root: &Path, fold: bool) -> Self {
        let mut spellings = vec![plain(root)];
        if let Ok(resolved) = fs::canonicalize(root) {
            let resolved = plain(&resolved);
            if !spellings.contains(&resolved) {
                spellings.push(resolved);
            }
        }
        Self {
            configured: root.to_path_buf(),
            spellings,
            fold,
        }
    }

    fn place(&self, path: &Path) -> Placement {
        let path = plain(path);
        for spelling in &self.spellings {
            if let Some(rest) = strip_root(&path, spelling, self.fold) {
                return if rest.as_os_str().is_empty() {
                    Placement::Root
                } else {
                    Placement::Below(self.configured.join(rest))
                };
            }
        }
        Placement::Elsewhere
    }
}

/// Adds one watcher result to `change`. Returns true when the watcher can no longer be trusted to
/// see this root (it was removed or reported an error) and should be started again.
fn absorb(mapper: &RootMapper, change: &mut SourceChange, result: notify::Result<Event>) -> bool {
    let event = match result {
        Ok(event) => event,
        Err(_) => {
            change.must_rescan = true;
            return true;
        }
    };
    // The watcher says it dropped events (an overflow): only a full enumeration is reliable.
    if event.need_rescan() {
        change.must_rescan = true;
    }
    if matches!(event.kind, EventKind::Access(_)) {
        return false;
    }
    let mut restart = false;
    for path in &event.paths {
        match mapper.place(path) {
            Placement::Below(path) => {
                // Files can be written into a new folder before the watcher covers it.
                if matches!(event.kind, EventKind::Create(CreateKind::Folder)) {
                    change.must_rescan = true;
                }
                change.paths.insert(path);
            }
            Placement::Root => {
                if event.kind.is_remove()
                    || matches!(event.kind, EventKind::Modify(ModifyKind::Name(_)))
                {
                    change.must_rescan = true;
                    restart = true;
                }
            }
            Placement::Elsewhere => change.must_rescan = true,
        }
    }
    if change.paths.len() > MAX_PENDING_PATHS {
        *change = SourceChange {
            must_rescan: true,
            ..SourceChange::default()
        };
    }
    restart
}

/// Collects the watcher's events into one [`SourceChange`] per burst and hands it to `deliver`.
/// Ends when the watcher (the sending side) is gone.
fn coalesce(
    events: Receiver<notify::Result<Event>>,
    mapper: RootMapper,
    window: Duration,
    stale: Arc<AtomicBool>,
    mut deliver: impl FnMut(SourceChange),
) {
    while let Ok(first) = events.recv() {
        let mut change = SourceChange::default();
        let mut restart = absorb(&mapper, &mut change, first);
        let end = Instant::now() + window;
        let mut open = true;
        while open {
            match events.recv_timeout(end.saturating_duration_since(Instant::now())) {
                Ok(next) => restart |= absorb(&mapper, &mut change, next),
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => open = false,
            }
        }
        if restart {
            stale.store(true, Ordering::Release);
        }
        if change.must_rescan || !change.paths.is_empty() {
            deliver(change);
        }
        if !open {
            return;
        }
    }
}

/// Why a watcher could not start, for the log. Only the kind is named: the `notify` error's own
/// text appends the paths it concerns (project folders and session ids below a source root) and
/// its generic variant carries a free-form message.
fn error_reason(kind: &notify::ErrorKind) -> String {
    match kind {
        notify::ErrorKind::Generic(_) => "watcher error".into(),
        notify::ErrorKind::Io(error) => format!("I/O error: {:?}", error.kind()),
        notify::ErrorKind::PathNotFound => "folder not found".into(),
        notify::ErrorKind::WatchNotFound => "watch not found".into(),
        notify::ErrorKind::InvalidConfig(_) => "invalid watcher configuration".into(),
        notify::ErrorKind::MaxFilesWatch => "OS file watch limit reached".into(),
    }
}

/// A running watcher; dropping it stops the watch and, with it, the coalescing thread.
struct Active {
    root: PathBuf,
    recursive: bool,
    stale: Arc<AtomicBool>,
    _watcher: RecommendedWatcher,
}

impl Active {
    fn start(root: &Path, recursive: bool, signal: Arc<PollSignal>) -> notify::Result<Self> {
        let (sender, events) = mpsc::channel();
        let mut watcher = RecommendedWatcher::new(sender, Config::default())?;
        watcher.watch(
            root,
            if recursive {
                RecursiveMode::Recursive
            } else {
                RecursiveMode::NonRecursive
            },
        )?;
        let stale = Arc::new(AtomicBool::new(false));
        let mapper = RootMapper::new(root);
        let flag = stale.clone();
        thread::Builder::new()
            .name("tokrate-watch".into())
            .spawn(move || {
                coalesce(events, mapper, COALESCE_WINDOW, flag, |change| {
                    signal.report(change)
                })
            })
            .map_err(notify::Error::io)?;
        Ok(Self {
            root: root.to_path_buf(),
            recursive,
            stale,
            _watcher: watcher,
        })
    }
}

/// The watchers of every source folder.
#[derive(Default)]
pub struct Watchers {
    active: HashMap<&'static str, Active>,
    /// Folders that exist but could not be watched (for example the Linux inotify limit), until
    /// the folder changes or goes away. They are logged once and rescanned at the idle cadence.
    failed: HashMap<&'static str, PathBuf>,
    last_fallback_rescan: Option<Instant>,
}

impl Watchers {
    /// Watches every folder that exists and drops the watcher of one that vanished, was replaced
    /// or can no longer be trusted, so a folder created or replaced after launch is picked up by
    /// the next poll. Run before each poll: a file written once its watcher exists is either
    /// reported by it or already visible to that poll.
    pub fn sync(&mut self, targets: &[WatchTarget], signal: &Arc<PollSignal>) {
        for target in targets {
            let source = target.source;
            if !target.exists {
                self.active.remove(source);
                self.failed.remove(source);
                continue;
            }
            if self.active.get(source).is_some_and(|active| {
                active.root != target.root
                    || active.recursive != target.recursive
                    || active.stale.load(Ordering::Acquire)
            }) {
                self.active.remove(source);
            }
            if self
                .failed
                .get(source)
                .is_some_and(|root| *root != target.root)
            {
                self.failed.remove(source);
            }
            if self.active.contains_key(source) || self.failed.contains_key(source) {
                continue;
            }
            match Active::start(&target.root, target.recursive, signal.clone()) {
                Ok(active) => {
                    self.active.insert(source, active);
                }
                Err(error) => {
                    eprintln!(
                        "tokrate: cannot watch the {source} folder ({}); checking it every {} s",
                        error_reason(&error.kind),
                        IDLE_POLL_INTERVAL.as_secs()
                    );
                    self.failed.insert(source, target.root.clone());
                }
            }
        }
    }

    /// Whether a folder without a watcher is due for a rescan. The monitors open a file that was
    /// not reported only when they enumerate, so this is what keeps such a folder current: every
    /// idle interval, never more often.
    pub fn fallback_rescan_due(&mut self) -> bool {
        if self.failed.is_empty() {
            return false;
        }
        let due = self
            .last_fallback_rescan
            .map_or(true, |last| last.elapsed() >= IDLE_POLL_INTERVAL);
        if due {
            self.last_fallback_rescan = Some(Instant::now());
        }
        due
    }

    #[cfg(test)]
    fn is_watching(&self, source: &str) -> bool {
        self.active.contains_key(source)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use notify::event::{AccessKind, DataChange, Flag, MetadataKind, RemoveKind, RenameMode};

    fn temporary(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("tokrate-watch-{name}-{}", rand::random::<u64>()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
    fn event(kind: EventKind, paths: &[&Path]) -> Event {
        paths.iter().fold(Event::new(kind), |event, path| {
            event.add_path(path.to_path_buf())
        })
    }
    fn modified(path: &Path) -> Event {
        event(
            EventKind::Modify(ModifyKind::Data(DataChange::Content)),
            &[path],
        )
    }

    #[test]
    fn verbatim_prefixes_are_removed_from_windows_paths() {
        assert_eq!(without_verbatim_prefix(r"\\?\C:\Users\a"), r"C:\Users\a");
        assert_eq!(
            without_verbatim_prefix(r"\\?\UNC\host\share\a"),
            r"\\host\share\a"
        );
        assert_eq!(without_verbatim_prefix(r"C:\Users\a"), r"C:\Users\a");
        assert_eq!(without_verbatim_prefix("/home/a"), "/home/a");
    }

    #[test]
    fn roots_compare_by_component_with_optional_case_folding() {
        let path = Path::new("/Users/Matti/.codex/sessions/2026/a.jsonl");
        let rest = |root: &str, fold| strip_root(path, Path::new(root), fold);
        assert_eq!(
            rest("/Users/Matti/.codex/sessions", false),
            Some(PathBuf::from("2026/a.jsonl"))
        );
        assert_eq!(rest("/users/matti/.codex/sessions", false), None);
        assert_eq!(
            rest("/users/matti/.codex/sessions", true),
            Some(PathBuf::from("2026/a.jsonl"))
        );
        // A sibling that shares a name prefix is not below the root.
        assert_eq!(rest("/Users/Matti/.codex/sess", false), None);
        assert_eq!(
            rest("/Users/Matti/.codex/sessions/2026/a.jsonl", false),
            Some(PathBuf::new())
        );
    }

    #[test]
    fn canonical_spellings_are_re_spelled_under_the_configured_root() {
        let real = temporary("canonical");
        let sessions = real.join("sessions");
        fs::create_dir_all(sessions.join("2026")).unwrap();
        let mapper = RootMapper::with_case_folding(&sessions, false);
        let canonical = fs::canonicalize(&sessions).unwrap();
        let file = Path::new("2026").join("a.jsonl");
        // As configured and as canonical (on macOS the temp folder is below /private).
        for root in [&sessions, &canonical] {
            assert_eq!(
                mapper.place(&root.join(&file)),
                Placement::Below(sessions.join(&file))
            );
            assert_eq!(mapper.place(root), Placement::Root);
        }
        assert_eq!(
            mapper.place(&real.join("other.jsonl")),
            Placement::Elsewhere
        );
        fs::remove_dir_all(real).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_root_maps_its_resolved_paths_back_to_the_link() {
        let real = temporary("symlink");
        let target = real.join("target");
        fs::create_dir_all(target.join("2026")).unwrap();
        let link = real.join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let mapper = RootMapper::with_case_folding(&link, false);
        let resolved = fs::canonicalize(&target)
            .unwrap()
            .join("2026")
            .join("a.jsonl");
        assert_eq!(
            mapper.place(&resolved),
            Placement::Below(link.join("2026").join("a.jsonl"))
        );
        fs::remove_dir_all(real).unwrap();
    }

    #[test]
    fn events_become_changes_under_the_configured_root() {
        let root = temporary("events");
        let mapper = RootMapper::with_case_folding(&root, false);
        let mut change = SourceChange::default();
        let file = root.join("a.jsonl");
        assert!(!absorb(&mapper, &mut change, Ok(modified(&file))));
        assert_eq!(change.paths, [file.clone()].into());
        assert!(!change.must_rescan);
        // Reads and metadata-only access are not changes.
        let mut quiet = SourceChange::default();
        absorb(
            &mapper,
            &mut quiet,
            Ok(event(EventKind::Access(AccessKind::Read), &[&file])),
        );
        assert_eq!(quiet, SourceChange::default());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn lost_events_errors_and_a_changed_root_request_a_rescan() {
        let root = temporary("rescan");
        let mapper = RootMapper::with_case_folding(&root, false);
        let rescan = |event: notify::Result<Event>| {
            let mut change = SourceChange::default();
            let restart = absorb(&mapper, &mut change, event);
            (change.must_rescan, restart)
        };
        let flagged = Event::new(EventKind::Other).set_flag(Flag::Rescan);
        assert_eq!(rescan(Ok(flagged)), (true, false));
        assert_eq!(
            rescan(Err(notify::Error::generic("overflow"))),
            (true, true)
        );
        let removed = event(EventKind::Remove(RemoveKind::Folder), &[&root]);
        assert_eq!(rescan(Ok(removed)), (true, true));
        let renamed = event(
            EventKind::Modify(ModifyKind::Name(RenameMode::From)),
            &[&root],
        );
        assert_eq!(rescan(Ok(renamed)), (true, true));
        // Touching the root folder itself is not structural.
        let touched = event(
            EventKind::Modify(ModifyKind::Metadata(MetadataKind::Any)),
            &[&root],
        );
        assert_eq!(rescan(Ok(touched)), (false, false));
        // An event outside every spelling of the root cannot be trusted.
        let elsewhere = modified(&std::env::temp_dir().join("elsewhere.jsonl"));
        assert_eq!(rescan(Ok(elsewhere)), (true, false));
        // A new folder can receive files before the watcher covers it.
        let folder = event(EventKind::Create(CreateKind::Folder), &[&root.join("new")]);
        assert_eq!(rescan(Ok(folder)), (true, false));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn an_overflow_of_paths_becomes_a_rescan() {
        let root = temporary("overflow");
        let mapper = RootMapper::with_case_folding(&root, false);
        let mut change = SourceChange::default();
        for index in 0..=MAX_PENDING_PATHS {
            absorb(
                &mapper,
                &mut change,
                Ok(modified(&root.join(format!("{index}.jsonl")))),
            );
        }
        assert!(change.must_rescan);
        assert!(change.paths.is_empty());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_burst_of_events_is_delivered_once() {
        let root = temporary("burst");
        let mapper = RootMapper::with_case_folding(&root, false);
        let (sender, events) = mpsc::channel();
        let (delivered, deliveries) = mpsc::channel();
        let stale = Arc::new(AtomicBool::new(false));
        let thread = {
            let stale = stale.clone();
            thread::spawn(move || {
                coalesce(
                    events,
                    mapper,
                    Duration::from_millis(200),
                    stale,
                    |change| delivered.send(change).unwrap(),
                )
            })
        };
        let started = Instant::now();
        for name in ["a", "b", "c"] {
            sender
                .send(Ok(modified(&root.join(format!("{name}.jsonl")))))
                .unwrap();
            thread::sleep(Duration::from_millis(20));
        }
        let change = deliveries.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(started.elapsed() >= Duration::from_millis(200));
        assert_eq!(change.paths.len(), 3);
        // Nothing else follows, and a lost root marks the watcher for a restart.
        assert!(deliveries.recv_timeout(Duration::from_millis(300)).is_err());
        sender.send(Err(notify::Error::generic("gone"))).unwrap();
        assert!(
            deliveries
                .recv_timeout(Duration::from_secs(5))
                .unwrap()
                .must_rescan
        );
        assert!(stale.load(Ordering::Acquire));
        drop(sender);
        thread.join().unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    /// Waits for a reported change that satisfies `wanted`.
    fn wait_for(signal: &PollSignal, wanted: impl Fn(&SourceChange) -> bool) -> bool {
        let end = Instant::now() + Duration::from_secs(10);
        let mut seen = SourceChange::default();
        while Instant::now() < end {
            let change = signal.take().change;
            seen.must_rescan |= change.must_rescan;
            seen.paths.extend(change.paths);
            if wanted(&seen) {
                return true;
            }
            thread::sleep(Duration::from_millis(25));
        }
        false
    }

    fn target(root: &Path, exists: bool) -> Vec<WatchTarget> {
        vec![WatchTarget {
            source: "codex",
            root: root.to_path_buf(),
            exists,
            recursive: true,
        }]
    }

    #[test]
    fn a_file_written_below_a_watched_root_is_reported_under_the_configured_path() {
        let dir = temporary("live");
        let root = dir.join("sessions");
        fs::create_dir_all(root.join("2026")).unwrap();
        let signal = Arc::new(PollSignal::default());
        let mut watchers = Watchers::default();
        watchers.sync(&target(&root, true), &signal);
        assert!(watchers.is_watching("codex"));
        let file = root.join("2026").join("rollout.jsonl");
        fs::write(&file, b"{}\n").unwrap();
        assert!(
            wait_for(&signal, |change| change.paths.contains(&file)),
            "no change reported for {}",
            file.display()
        );
        // Appending to the known file is reported too.
        signal.take();
        let mut handle = fs::OpenOptions::new().append(true).open(&file).unwrap();
        std::io::Write::write_all(&mut handle, b"{}\n").unwrap();
        drop(handle);
        assert!(wait_for(&signal, |change| change.paths.contains(&file)));
        fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_file_below_a_symlinked_root_is_reported_under_the_link() {
        let dir = temporary("linked");
        let target_dir = dir.join("target");
        fs::create_dir_all(&target_dir).unwrap();
        let link = dir.join("link");
        std::os::unix::fs::symlink(&target_dir, &link).unwrap();
        let signal = Arc::new(PollSignal::default());
        let mut watchers = Watchers::default();
        watchers.sync(&target(&link, true), &signal);
        assert!(watchers.is_watching("codex"));
        let file = link.join("rollout.jsonl");
        fs::write(&file, b"{}\n").unwrap();
        assert!(wait_for(&signal, |change| change.paths.contains(&file)));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_missing_folder_gets_no_watcher_until_it_exists() {
        let dir = temporary("missing");
        let root = dir.join("sessions");
        let signal = Arc::new(PollSignal::default());
        let mut watchers = Watchers::default();
        watchers.sync(&target(&root, false), &signal);
        assert!(!watchers.is_watching("codex"));
        assert!(!watchers.fallback_rescan_due());
        fs::create_dir_all(&root).unwrap();
        watchers.sync(&target(&root, true), &signal);
        assert!(watchers.is_watching("codex"));
        // A folder that vanished loses its watcher, and a replaced one is watched again.
        watchers.sync(&target(&root, false), &signal);
        assert!(!watchers.is_watching("codex"));
        watchers.sync(&target(&root, true), &signal);
        assert!(watchers.is_watching("codex"));
        let other = dir.join("other");
        fs::create_dir_all(&other).unwrap();
        watchers.sync(&target(&other, true), &signal);
        assert_eq!(watchers.active["codex"].root, other);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_folder_that_cannot_be_watched_is_rescanned_at_the_idle_cadence() {
        let mut watchers = Watchers::default();
        watchers
            .failed
            .insert("codex", PathBuf::from("/unwatchable"));
        assert!(watchers.fallback_rescan_due());
        assert!(!watchers.fallback_rescan_due());
        watchers.last_fallback_rescan = Some(Instant::now() - IDLE_POLL_INTERVAL);
        assert!(watchers.fallback_rescan_due());
        // The failure is dropped when the folder goes away, so it is tried again later.
        let signal = Arc::new(PollSignal::default());
        watchers.sync(&target(Path::new("/unwatchable"), false), &signal);
        assert!(!watchers.fallback_rescan_due());
    }

    #[test]
    fn a_start_failure_is_logged_by_kind_without_paths_or_messages() {
        let secret = "/home/someone/.claude/projects/-home-someone-secret/0b1f.jsonl";
        let errors = [
            notify::Error::generic(secret).add_path(PathBuf::from(secret)),
            notify::Error::io(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                secret,
            ))
            .add_path(PathBuf::from(secret)),
            notify::Error::path_not_found().add_path(PathBuf::from(secret)),
            notify::Error::watch_not_found().add_path(PathBuf::from(secret)),
            notify::Error::new(notify::ErrorKind::MaxFilesWatch).add_path(PathBuf::from(secret)),
            notify::Error::new(notify::ErrorKind::InvalidConfig(Config::default()))
                .add_path(PathBuf::from(secret)),
        ];
        for error in &errors {
            let reason = error_reason(&error.kind);
            assert!(
                !reason.contains("secret") && !reason.contains("/home"),
                "{reason}"
            );
        }
        assert_eq!(error_reason(&errors[1].kind), "I/O error: PermissionDenied");
        assert_eq!(error_reason(&errors[4].kind), "OS file watch limit reached");
    }
}
