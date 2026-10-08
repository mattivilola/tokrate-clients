//! Helpers for tests that put a named pipe where a file is expected.

/// Creates a named pipe: opening it for reading blocks until something writes to it.
#[cfg(unix)]
pub fn make_fifo(path: &std::path::Path) {
    let status = std::process::Command::new("mkfifo")
        .arg(path)
        .status()
        .unwrap();
    assert!(status.success());
}

/// Runs `work` on another thread and fails the test, instead of hanging it, when it blocks.
#[cfg(unix)]
pub fn within_seconds<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> T {
    let (sender, receiver) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = sender.send(work());
    });
    receiver
        .recv_timeout(std::time::Duration::from_secs(20))
        .expect("blocked on a file that is not a regular file")
}
