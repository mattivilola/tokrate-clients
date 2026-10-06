import Foundation

/// Lets the polling task sleep until a deadline or until a folder watcher reports a change.
///
/// This is not an `AsyncStream`: cancelling a task that awaits a stream's iterator terminates the
/// stream, so racing a timer against it would lose every later wake-up. Here the waiter's continuation
/// is resumed exactly once, by `signal()`, by the timeout, or by cancellation of the waiting task.
actor PollWaker {
    private var isSignalled = false
    private var waiter: (id: Int, continuation: CheckedContinuation<Bool, Never>)?
    private var timer: Task<Void, Never>?
    private var nextID = 0

    /// Wakes the current waiter, or makes the next `wait` return at once, so a change reported between
    /// two waits is not lost.
    func signal() {
        if waiter != nil { resume(with: true) } else { isSignalled = true }
    }

    /// Returns true when signalled and false on timeout or cancellation.
    func wait(timeout: TimeInterval) async -> Bool {
        if isSignalled {
            isSignalled = false
            return true
        }
        guard timeout > 0, !Task.isCancelled else { return false }
        nextID += 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter = (id, continuation)
                timer = Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    if !Task.isCancelled { await self.expire(id) }
                }
            }
        } onCancel: {
            Task { await self.expire(id) }
        }
    }

    /// Ends the wait `id` unless it was already ended; a stale timer or cancellation is a no-op.
    private func expire(_ id: Int) {
        if waiter?.id == id { resume(with: false) }
    }

    private func resume(with signalled: Bool) {
        guard let waiter else { return }
        self.waiter = nil
        timer?.cancel()
        timer = nil
        waiter.continuation.resume(returning: signalled)
    }
}
