import XCTest
@testable import CctopMenubar

final class GhosttyCLIFocusTests: XCTestCase {
    private typealias Snapshot = GhosttyCLIRuntimeProbe.ProcessSnapshot
    private let project = "/Users/test/projects/myapp"

    private func snapshot(
        pid: UInt32 = 30, tty: String? = "/dev/ttys002", directory: String? = "/Users/test/projects/myapp"
    ) -> Snapshot {
        Snapshot(pid: pid, parentPID: 20, startTime: 123, command: "codex", tty: tty,
                 directory: directory, isForeground: true, isSuspended: false)
    }

    private func probe(_ candidates: [Snapshot]) -> GhosttyCLIRuntimeProbe {
        var parents: [UInt32: Snapshot] = [20: snapshot(pid: 20), 10: snapshot(pid: 10)]
        parents[20]?.parentPID = 10
        parents[10]?.parentPID = 1
        let byPID = Dictionary(candidates.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return GhosttyCLIRuntimeProbe(
            processes: { candidates },
            process: { byPID[$0] ?? parents[$0] },
            hostPIDs: { [10] }
        )
    }

    private func session(id: String = "first") -> SessionData {
        var session = SessionData.mock(id: id, project: "myapp", terminal: TerminalInfo(program: "ghostty"))
        session.source = "codex"
        return session
    }

    func testSharedDaemonChatsRecoverTheCodexPaneInsteadOfMatchingTheEditorDirectory() {
        for id in ["first", "second"] {
            let session = session(id: id)
            let strategy = probe([snapshot()]).resolve(session: session, strategy: resolveFocusStrategy(session: session))
            guard case .ghostty(let target) = strategy else { return XCTFail("Expected the live CLI pane") }
            XCTAssertEqual(target.tty, "/dev/ttys002")
            XCTAssertEqual(target.restoreDirectory, project)
            XCTAssertNil(session.terminal?.tty, "Live discovery must not rewrite the session record")
        }
    }

    func testMissingProcessEvidenceDoesNotFallBackToTheEditorDirectory() {
        let session = session()
        XCTAssertEqual(
            probe([]).resolve(session: session, strategy: resolveFocusStrategy(session: session)),
            .activateByBundleID("com.mitchellh.ghostty")
        )
    }

    private func recoveredTarget(_ candidates: [Snapshot]) throws -> GhosttyFocusTarget {
        let session = session()
        let strategy = probe(candidates).resolve(session: session, strategy: resolveFocusStrategy(session: session))
        guard case .ghostty(let target) = strategy else { throw NSError(domain: "Expected CLI target", code: 1) }
        return target
    }

    func testUniqueProjectMatchWinsOverOtherPanes() throws {
        let target = try recoveredTarget([
            snapshot(pid: 31, tty: "/dev/ttys003", directory: "/Users/test/other"), snapshot()
        ])
        XCTAssertEqual(target.tty, "/dev/ttys002")
    }

    func testOnlyPaneCanServeChatsFromAnotherProjectAndRestoresItsOwnDirectory() throws {
        let target = try recoveredTarget([snapshot(directory: "/Users/test/other")])
        XCTAssertEqual(target.tty, "/dev/ttys002")
        XCTAssertEqual(target.restoreDirectory, "/Users/test/other")
    }

    func testProcessesSharingOneTTYDoNotMakeThePaneAmbiguous() throws {
        XCTAssertEqual(try recoveredTarget([snapshot(), snapshot(pid: 31)]).tty, "/dev/ttys002")
    }

    func testMultipleMatchingPanesAndMultipleUnmatchedPanesAreAmbiguous() {
        let session = session()
        for directory in [project, "/Users/test/other"] {
            let candidates = [snapshot(directory: directory), snapshot(pid: 31, tty: "/dev/ttys003", directory: directory)]
            XCTAssertEqual(probe(candidates).resolve(session: session, strategy: resolveFocusStrategy(session: session)),
                           .activateByBundleID("com.mitchellh.ghostty"))
        }
    }

    func testIneligibleProcessesCannotSupplyAPane() {
        let session = session()
        var editor = snapshot(); editor.command = "nvim"
        var background = snapshot(); background.isForeground = false
        var suspended = snapshot(); suspended.isSuspended = true
        var detached = snapshot(); detached.parentPID = 1
        let candidates = [editor, background, suspended, detached, snapshot(tty: nil),
                          snapshot(tty: "/tmp/ttys002"), snapshot(directory: nil), snapshot(directory: "relative")]
        for candidate in candidates {
            XCTAssertEqual(probe([candidate]).resolve(session: session, strategy: resolveFocusStrategy(session: session)),
                           .activateByBundleID("com.mitchellh.ghostty"))
        }
    }

    func testRevalidationRejectsExitedReusedAndRetargetedProcesses() {
        let session = session()
        var reused = snapshot(); reused.startTime += 1
        var retargeted = snapshot(); retargeted.tty = "/dev/ttys003"
        var background = snapshot(); background.isForeground = false
        for replacement: Snapshot? in [nil, reused, retargeted, background] {
            var runtime = probe([snapshot()])
            let lookup = runtime.process
            runtime.process = { $0 == 30 ? replacement : lookup($0) }
            XCTAssertEqual(runtime.resolve(session: session, strategy: resolveFocusStrategy(session: session)),
                           .activateByBundleID("com.mitchellh.ghostty"))
        }
    }

    func testMissingHostUnreadableParentsAndCyclicParentsFailClosed() {
        let session = session()
        for mode in 0..<3 {
            var runtime = probe([snapshot()])
            if mode == 0 { runtime.hostPIDs = { [] } }
            if mode == 1 { runtime.process = { _ in nil } }
            if mode == 2 {
                let cycle = snapshot(pid: 20)
                runtime.process = { _ in cycle }
            }
            XCTAssertEqual(runtime.resolve(session: session, strategy: resolveFocusStrategy(session: session)),
                           .activateByBundleID("com.mitchellh.ghostty"))
        }
    }

    func testRecoveredPaneNeverFallsBackToTheSharedProjectDirectory() throws {
        let target = try recoveredTarget([snapshot()])
        XCTAssertTrue(target.requiresExactPane)
        XCTAssertEqual(ghosttyFocusCandidateDirectories(target: target, markerPrimed: true), [target.matchDirectory])
        XCTAssertEqual(ghosttyFocusCandidateDirectories(target: target, markerPrimed: false), [])
    }

    func testInvalidRecordedTTYCanRecoverTheLivePane() {
        var session = session()
        session.terminal = TerminalInfo(program: "ghostty", tty: "/tmp/not-a-terminal")
        let strategy = probe([snapshot()]).resolve(session: session, strategy: resolveFocusStrategy(session: session))
        guard case .ghostty(let target) = strategy else { return XCTFail("Expected the live CLI pane") }
        XCTAssertEqual(target.tty, "/dev/ttys002")
    }

    func testRecordedTTYOtherClientsDesktopAndMultiplexersSkipDiscovery() {
        var runtime = probe([])
        runtime.processes = { XCTFail("Discovery should not run"); return [] }
        var recorded = session(); recorded.terminal = TerminalInfo(program: "ghostty", tty: "/dev/ttys007")
        var otherClient = session(); otherClient.source = "cc"
        var desktop = session(); desktop.terminal = TerminalInfo(program: "")
        var multiplexed = session()
        multiplexed.terminal = TerminalInfo(program: "ghostty", multiplexer: .tmux(socket: "/tmp/tmux", paneId: "%1", binaryPath: nil))
        for session in [recorded, otherClient, desktop, multiplexed] {
            let strategy = resolveFocusStrategy(session: session)
            XCTAssertEqual(runtime.resolve(session: session, strategy: strategy), strategy)
        }
    }
}
