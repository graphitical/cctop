import AppKit
import Darwin

struct GhosttyCLIRuntimeProbe {
    struct ProcessSnapshot: Equatable {
        var pid: UInt32
        var parentPID: UInt32
        var startTime: TimeInterval
        var command: String
        var tty: String?
        var directory: String?
        var isForeground: Bool
        var isSuspended: Bool

        var isEligible: Bool {
            SessionData.harnessOwningComm(command) == SessionData.codexSource
                && isForeground && !isSuspended && directory?.hasPrefix("/") == true
                && tty?.range(of: #"^/dev/ttys\d+$"#, options: .regularExpression) != nil
        }
    }

    var processes: () -> [ProcessSnapshot]
    var process: (UInt32) -> ProcessSnapshot?
    var hostPIDs: () -> Set<UInt32>

    init(
        processes: @escaping () -> [ProcessSnapshot] = Self.liveProcesses,
        process: @escaping (UInt32) -> ProcessSnapshot? = Self.liveProcess,
        hostPIDs: @escaping () -> Set<UInt32> = Self.liveHostPIDs
    ) {
        self.processes = processes
        self.process = process
        self.hostPIDs = hostPIDs
    }

    func resolve(session: SessionData, strategy: FocusStrategy) -> FocusStrategy {
        guard session.isCodex, session.terminal?.multiplexer == nil,
              case .ghostty(let target) = strategy, target.tty == nil else { return strategy }
        guard let candidate = candidate(projectPath: session.projectPath) else {
            return .activateByBundleID("com.mitchellh.ghostty")
        }
        var recovered = ghosttyFocusTarget(
            for: session, ttyOverride: candidate.tty, restoreDirectoryOverride: candidate.directory
        )
        recovered.requiresExactPane = true
        return .ghostty(recovered)
    }

    private func candidate(projectPath: String) -> ProcessSnapshot? {
        let hosts = hostPIDs()
        guard !hosts.isEmpty else { return nil }
        let candidates = processes().filter { $0.isEligible && belongsToGhostty($0, hosts: hosts) }
        let project = Self.canonicalDirectory(projectPath)
        let matching = candidates.filter { $0.directory.map(Self.canonicalDirectory) == project }
        let pool = matching.isEmpty ? candidates : matching
        guard let candidate = pool.first, Set(pool.compactMap(\.tty)).count == 1,
              let verified = process(candidate.pid), verified == candidate,
              belongsToGhostty(verified, hosts: hosts) else { return nil }
        return verified
    }

    private func belongsToGhostty(_ candidate: ProcessSnapshot, hosts: Set<UInt32>) -> Bool {
        var ancestor = candidate.parentPID
        var visited: Set<UInt32> = [candidate.pid]
        while ancestor > 1, visited.insert(ancestor).inserted {
            if hosts.contains(ancestor) { return true }
            // Ghostty's login intermediary can be root-owned, outside the user process list.
            guard let parent = process(ancestor) else { return false }
            ancestor = parent.parentPID
        }
        return false
    }

    private static func canonicalDirectory(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func liveHostPIDs() -> Set<UInt32> {
        Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.mitchellh.ghostty")
            .compactMap { UInt32(exactly: $0.processIdentifier) })
    }

    static func liveProcesses() -> [ProcessSnapshot] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = entries.count * stride
        guard entries.withUnsafeMutableBytes({
            sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0)
        }) == 0 else { return [] }
        return entries.prefix(size / stride).compactMap { entry in
            guard SessionData.harnessOwningComm(SessionData.commandName(from: entry)) == SessionData.codexSource,
                  let pid = UInt32(exactly: entry.kp_proc.p_pid) else { return nil }
            return liveProcess(pid)
        }
    }

    static func liveProcess(_ pid: UInt32) -> ProcessSnapshot? {
        guard let info = SessionData.processInfo(pid: pid), info.kp_proc.p_stat != 5 else { return nil }
        let start = info.kp_proc.p_starttime
        let tty = info.kp_eproc.e_tdev == UInt32.max ? nil : devname(info.kp_eproc.e_tdev, S_IFCHR)
            .map { "/dev/" + String(cString: $0) }
        return ProcessSnapshot(
            pid: pid, parentPID: UInt32(info.kp_eproc.e_ppid),
            startTime: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000,
            command: SessionData.commandName(from: info), tty: tty, directory: workingDirectory(pid),
            isForeground: info.kp_eproc.e_pgid == info.kp_eproc.e_tpgid,
            isSuspended: info.kp_proc.p_stat == 4
        )
    }

    private static func workingDirectory(_ pid: UInt32) -> String? {
        guard let processID = pid_t(exactly: pid) else { return nil }
        var paths = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDVNODEPATHINFO, 0, &paths, size) == size else { return nil }
        return withUnsafePointer(to: &paths.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
