import Foundation

@inline(__always)
func terminalRunOnMain(
    _ operation: @escaping @MainActor () -> Void
) {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            operation()
        }
        return
    }

    terminalEnqueueOnMain(operation)
}

/// Defers work until the current Ghostty call has returned, even on the main thread.
func terminalEnqueueOnMain(
    _ operation: @escaping @MainActor () -> Void
) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            operation()
        }
    }
}
