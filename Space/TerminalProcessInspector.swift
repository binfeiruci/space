import Darwin
import Foundation

protocol TerminalProcessInspecting: Sendable {
    func processNames(
        for requests: [TerminalProcessInspector.Request]
    ) async -> [UUID: String]
}

enum TerminalRuntimeMonitoringPolicy {
    static func interval(
        applicationIsActive: Bool,
        sidebarIsVisible: Bool
    ) -> Duration {
        if !applicationIsActive { return .seconds(1) }
        return sidebarIsVisible ? .milliseconds(250) : .milliseconds(750)
    }
}

actor TerminalProcessInspector: TerminalProcessInspecting {
    private var ttyDeviceByName: [String: UInt64] = [:]

    nonisolated struct Request: Sendable {
        let sessionID: UUID
        let processGroupID: pid_t
        let ttyName: String
    }

    nonisolated struct ProcessSnapshot: Sendable {
        let processID: pid_t
        let parentProcessID: pid_t
        let processGroupID: pid_t
        let ttyDevice: UInt64?
        let terminalForegroundProcessGroupID: pid_t
        let name: String

        init(
            processID: pid_t,
            parentProcessID: pid_t,
            processGroupID: pid_t,
            ttyDevice: UInt64?,
            terminalForegroundProcessGroupID: pid_t? = nil,
            name: String
        ) {
            self.processID = processID
            self.parentProcessID = parentProcessID
            self.processGroupID = processGroupID
            self.ttyDevice = ttyDevice
            self.terminalForegroundProcessGroupID =
                terminalForegroundProcessGroupID ?? processGroupID
            self.name = name
        }
    }

    private struct ProcessIdentitySnapshot {
        let processID: pid_t
        let parentProcessID: pid_t
        let processGroupID: pid_t
        let ttyDevice: UInt64?
        let terminalForegroundProcessGroupID: pid_t
    }

    func processNames(for requests: [Request]) -> [UUID: String] {
        guard !requests.isEmpty else { return [:] }

        let identities = processIdentitySnapshots()
        let childrenByParent = Dictionary(grouping: identities) {
            $0.parentProcessID
        }
        var processNameByID: [pid_t: String] = [:]
        var namesBySessionID: [UUID: String] = [:]

        for request in requests {
            guard let ttyDevice = ttyDevice(for: request.ttyName),
                  let process = Self.resolveForegroundProcess(
                      processGroupID: request.processGroupID,
                      ttyDevice: ttyDevice,
                      processes: processSnapshots(
                          processGroupID: request.processGroupID,
                          ttyDevice: ttyDevice,
                          identities: identities,
                          childrenByParent: childrenByParent,
                          processNameByID: &processNameByID
                      )
                  ) else { continue }
            namesBySessionID[request.sessionID] = process.name
        }
        return namesBySessionID
    }

    nonisolated static func resolveForegroundProcess(
        processGroupID: pid_t,
        ttyDevice: UInt64,
        processes: [ProcessSnapshot]
    ) -> ProcessSnapshot? {
        guard processGroupID > 0 else { return nil }
        let candidates = processes.filter {
            $0.processGroupID == processGroupID
                && $0.ttyDevice == ttyDevice
        }
        guard !candidates.isEmpty else { return nil }

        let processByID = Dictionary(
            uniqueKeysWithValues: processes.map { ($0.processID, $0) }
        )
        let selected: ProcessSnapshot
        if let leader = candidates.first(where: {
            $0.processID == processGroupID
        }), leader.name != "login", !leader.name.isEmpty {
            selected = leader
        } else {
            let usableCandidates = candidates.filter {
                $0.name != "login" && !$0.name.isEmpty
            }
            guard let candidate = usableCandidates.max(by: { lhs, rhs in
                let lhsDepth = processDepth(lhs, processByID: processByID)
                let rhsDepth = processDepth(rhs, processByID: processByID)
                if lhsDepth == rhsDepth {
                    return lhs.processID < rhs.processID
                }
                return lhsDepth < rhsDepth
            }) else { return nil }
            selected = candidate
        }

        let nestedForegroundProcesses = processes.filter { process in
            guard process.ttyDevice != nil,
                  process.ttyDevice != ttyDevice,
                  process.processGroupID
                    == process.terminalForegroundProcessGroupID,
                  !process.name.isEmpty
            else { return false }
            return isDescendant(
                process,
                of: selected.processID,
                processByID: processByID
            )
        }

        return nestedForegroundProcesses.max(by: { lhs, rhs in
            let lhsDepth = foregroundGroupDepth(
                lhs,
                processByID: processByID
            )
            let rhsDepth = foregroundGroupDepth(
                rhs,
                processByID: processByID
            )
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }

            let sameGroup = lhs.ttyDevice == rhs.ttyDevice
                && lhs.processGroupID == rhs.processGroupID
            if sameGroup {
                let lhsIsLeader = lhs.processID == lhs.processGroupID
                    && lhs.name != "login"
                let rhsIsLeader = rhs.processID == rhs.processGroupID
                    && rhs.name != "login"
                if lhsIsLeader != rhsIsLeader { return !lhsIsLeader }
            }
            return lhs.processID < rhs.processID
        }) ?? selected
    }

    nonisolated private static func foregroundGroupDepth(
        _ process: ProcessSnapshot,
        processByID: [pid_t: ProcessSnapshot]
    ) -> Int {
        let groupLeader = processByID[process.processGroupID] ?? process
        return processDepth(groupLeader, processByID: processByID)
    }

    nonisolated private static func isDescendant(
        _ process: ProcessSnapshot,
        of ancestorProcessID: pid_t,
        processByID: [pid_t: ProcessSnapshot]
    ) -> Bool {
        var parentProcessID = process.parentProcessID
        var visited = Set([process.processID])
        while parentProcessID > 0, !visited.contains(parentProcessID) {
            if parentProcessID == ancestorProcessID { return true }
            visited.insert(parentProcessID)
            guard let parent = processByID[parentProcessID] else {
                return false
            }
            parentProcessID = parent.parentProcessID
        }
        return false
    }

    nonisolated private static func processDepth(
        _ process: ProcessSnapshot,
        processByID: [pid_t: ProcessSnapshot]
    ) -> Int {
        var depth = 0
        var parentProcessID = process.parentProcessID
        var visited = Set([process.processID])
        while parentProcessID > 0,
              !visited.contains(parentProcessID),
              let parent = processByID[parentProcessID] {
            visited.insert(parentProcessID)
            depth += 1
            parentProcessID = parent.parentProcessID
        }
        return depth
    }

    private func ttyDevice(for ttyName: String) -> UInt64? {
        if let cached = ttyDeviceByName[ttyName] {
            return cached
        }
        var fileStatus = stat()
        guard Darwin.lstat(ttyName, &fileStatus) == 0 else { return nil }
        let device = UInt64(fileStatus.st_rdev)
        ttyDeviceByName[ttyName] = device
        return device
    }

    private func processSnapshots(
        processGroupID: pid_t,
        ttyDevice: UInt64,
        identities: [ProcessIdentitySnapshot],
        childrenByParent: [pid_t: [ProcessIdentitySnapshot]],
        processNameByID: inout [pid_t: String]
    ) -> [ProcessSnapshot] {
        let rootProcessIDs = identities.compactMap { process in
            process.processGroupID == processGroupID
                && process.ttyDevice == ttyDevice
                ? process.processID
                : nil
        }
        guard !rootProcessIDs.isEmpty else { return [] }

        var relevantProcessIDs = Set(rootProcessIDs)
        var pendingProcessIDs = rootProcessIDs
        while let parentProcessID = pendingProcessIDs.popLast() {
            for child in childrenByParent[parentProcessID] ?? []
            where relevantProcessIDs.insert(child.processID).inserted {
                pendingProcessIDs.append(child.processID)
            }
        }

        return identities.compactMap { process in
            guard relevantProcessIDs.contains(process.processID) else {
                return nil
            }
            return ProcessSnapshot(
                processID: process.processID,
                parentProcessID: process.parentProcessID,
                processGroupID: process.processGroupID,
                ttyDevice: process.ttyDevice,
                terminalForegroundProcessGroupID:
                    process.terminalForegroundProcessGroupID,
                name: cachedProcessName(
                    for: process.processID,
                    cache: &processNameByID
                )
            )
        }
    }

    private func cachedProcessName(
        for processID: pid_t,
        cache: inout [pid_t: String]
    ) -> String {
        if let cached = cache[processID] {
            return cached
        }
        let name = processName(for: processID) ?? ""
        cache[processID] = name
        return name
    }

    private func processIdentitySnapshots() -> [ProcessIdentitySnapshot] {
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var byteCount = 0
        guard sysctl(&query, u_int(query.count), nil, &byteCount, nil, 0) == 0,
              byteCount >= MemoryLayout<kinfo_proc>.stride
        else { return [] }

        var entries = [kinfo_proc](
            repeating: kinfo_proc(),
            count: byteCount / MemoryLayout<kinfo_proc>.stride
        )
        let result = entries.withUnsafeMutableBytes { buffer in
            sysctl(
                &query,
                u_int(query.count),
                buffer.baseAddress,
                &byteCount,
                nil,
                0
            )
        }
        guard result == 0 else { return [] }

        let entryCount = min(
            entries.count,
            byteCount / MemoryLayout<kinfo_proc>.stride
        )
        return entries.prefix(entryCount).compactMap {
            entry -> ProcessIdentitySnapshot? in
            let processID = entry.kp_proc.p_pid
            let ttyDevice = entry.kp_eproc.e_tdev
            guard processID > 0 else { return nil }
            return ProcessIdentitySnapshot(
                processID: processID,
                parentProcessID: entry.kp_eproc.e_ppid,
                processGroupID: entry.kp_eproc.e_pgid,
                ttyDevice: ttyDevice >= 0 ? UInt64(ttyDevice) : nil,
                terminalForegroundProcessGroupID: entry.kp_eproc.e_tpgid
            )
        }
    }

    private func processName(for processID: pid_t) -> String? {
        var pathBuffer = [UInt8](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(
            processID,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        if pathLength > 0 {
            let path = String(
                decoding: pathBuffer.prefix(Int(pathLength)),
                as: UTF8.self
            )
            let name = URL(fileURLWithPath: path).lastPathComponent
            if !name.isEmpty { return name }
        }

        var nameBuffer = [CChar](repeating: 0, count: 256)
        let nameLength = proc_name(
            processID,
            &nameBuffer,
            UInt32(nameBuffer.count)
        )
        guard nameLength > 0 else { return nil }
        return String(cString: nameBuffer)
    }
}
