import CoreServices
import Foundation

struct WorkspaceFileChanges: Sendable {
    var paths: Set<String> = []
    var directoryPaths: Set<String> = []
    var requiresFullScan = false

    var isEmpty: Bool {
        paths.isEmpty && !requiresFullScan
    }

    mutating func formUnion(_ other: WorkspaceFileChanges) {
        paths.formUnion(other.paths)
        directoryPaths.formUnion(other.directoryPaths)
        requiresFullScan = requiresFullScan || other.requiresFullScan
    }
}

final class WorkspaceFileWatcher {
    private let queue = DispatchQueue(
        label: "Space.WorkspaceFileWatcher",
        qos: .utility
    )
    private let queueKey = DispatchSpecificKey<Void>()
    private let onChange: @MainActor (WorkspaceFileChanges) -> Void
    private var stream: FSEventStreamRef?
    private var watchedRootPaths: [String] = []
    private var pendingNotification: DispatchWorkItem?
    private var pendingChanges = WorkspaceFileChanges()

    init(onChange: @escaping @MainActor (WorkspaceFileChanges) -> Void) {
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stop()
    }

    func start(watching urls: [URL]) {
        performOnQueue {
            self.stopOnQueue()
            let rootPaths = urls.map { $0.standardizedFileURL.path }
            guard !rootPaths.isEmpty else { return }
            self.watchedRootPaths = rootPaths

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = {
                _, clientInfo, eventCount, eventPaths, eventFlags, _ in
                guard let clientInfo else { return }
                let watcher = Unmanaged<WorkspaceFileWatcher>
                    .fromOpaque(clientInfo)
                    .takeUnretainedValue()
                let pathPointers = eventPaths.assumingMemoryBound(
                    to: UnsafePointer<CChar>?.self
                )
                var changes = WorkspaceFileChanges()

                for index in 0 ..< eventCount {
                    guard let pathPointer = pathPointers[index] else { continue }
                    let path = String(cString: pathPointer)
                    let flags = eventFlags[index]
                    changes.paths.insert(path)
                    if WorkspaceFileWatcher.requiresFullScan(flags) {
                        changes.requiresFullScan = true
                    }
                    if WorkspaceFileWatcher.isDirectoryStructureChange(flags) {
                        changes.directoryPaths.insert(path)
                    }
                }
                watcher.scheduleNotification(changes)
            }
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
            )

            guard let stream = FSEventStreamCreate(
                nil,
                callback,
                &context,
                rootPaths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.2,
                flags
            ) else { return }

            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, self.queue)
            FSEventStreamStart(stream)
        }
    }

    private func stop() {
        performOnQueue {
            self.stopOnQueue()
        }
    }

    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingNotification?.cancel()
        pendingNotification = nil
        pendingChanges = WorkspaceFileChanges()
        watchedRootPaths = []
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleNotification(_ changes: WorkspaceFileChanges) {
        dispatchPrecondition(condition: .onQueue(queue))
        pendingNotification?.cancel()
        pendingChanges.formUnion(changes)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var changes = self.pendingChanges
            self.pendingChanges = WorkspaceFileChanges()
            if changes.requiresFullScan {
                changes.paths = Set(self.watchedRootPaths)
                changes.directoryPaths = Set(self.watchedRootPaths)
            }
            guard !changes.isEmpty else { return }
            Task { @MainActor in
                self.onChange(changes)
            }
        }
        pendingNotification = workItem
        queue.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func performOnQueue(_ action: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            action()
        } else {
            queue.sync(execute: action)
        }
    }

    private static func requiresFullScan(
        _ flags: FSEventStreamEventFlags
    ) -> Bool {
        flags & (
            FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
                | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
                | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
                | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
                | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
        ) != 0
    }

    private static func isDirectoryStructureChange(
        _ flags: FSEventStreamEventFlags
    ) -> Bool {
        guard !requiresFullScan(flags) else { return true }
        let changesItem = flags & (
            FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
                | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)
                | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        ) != 0
        let itemIsDirectory = flags
            & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
        return changesItem && itemIsDirectory
    }
}
