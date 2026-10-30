import ConcurrencyExtras
import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Foundation
import Observation
import Testing
@testable import CtrlxServerFeature

@MainActor
struct LocalSessionGroupingCacheTests {
    @Test("Host grouping invalidates on tmux changes and keeps cached reads observable")
    func paneChanges() async {
        let rows = LockIsolated(row(name: "work", width: 80))
        await withDependencies {
            $0[ProcessRunner.self].run = { _, arguments, _, _ in
                .init(exitCode: 0, stdout: Data((arguments.contains("list-panes") ? rows.value : "").utf8), stderr: Data())
            }
        } operation: {
            let service = TmuxService(tmuxPath: "/usr/bin/true")
            await service.refreshPanes()
            #expect(service.session(named: "work")?.windows.first?.panes.first?.width == 80)
            _ = service.sessions
            let changes = LockIsolated(0)
            withObservationTracking { _ = service.sessions } onChange: { changes.withValue { $0 += 1 } }
            rows.setValue(row(name: "renamed", width: 120))
            await service.refreshPanes()
            #expect(changes.value == 1)
            #expect(service.session(named: "work") == nil)
            #expect(service.session(named: "renamed")?.windows.first?.panes.first?.width == 120)
            #expect(service.windows.first?.sessionName == "renamed")
            #expect(service.sessions.first?.sessionName == "renamed")
            rows.setValue("")
            await service.refreshPanes()
            #expect(service.windows.isEmpty)
            #expect(service.sessions.isEmpty)
            #expect(service.session(named: "renamed") == nil)
        }
    }

    @Test("Resource changes invalidate sessions while retaining targeted resource-only lookup")
    func resources() {
        let service = TmuxService(tmuxPath: "/usr/bin/true")
        _ = service.sessions
        let first = ResourceSession(id: UUID(), name: "files", directory: "/repo")
        let changes = LockIsolated(0)
        withObservationTracking { _ = service.sessions } onChange: { changes.withValue { $0 += 1 } }
        service.resourceSessions = [first]
        #expect(changes.value == 1)
        #expect(service.session(named: "files")?.resourceSession == first)
        #expect(service.sessions.first?.resourceSession == first)
        service.resourceSessions[0].name = "renamed"
        #expect(service.session(named: "files") == nil)
        #expect(service.sessions.first?.sessionName == "renamed")
        service.resourceSessions = []
        #expect(service.sessions.isEmpty)
    }

    @Test("A thousand repeated graph reads group the same snapshot only once")
    func repeatedReads() {
        let service = TmuxService(tmuxPath: "/usr/bin/true")
        service.resourceSessions = [.init(id: UUID(), name: "files", directory: "/repo")]
        let metrics = HostPerformanceMetrics.shared
        let wasEnabled = metrics.begin() != nil
        if !wasEnabled {
            metrics.setEnabled(true)
        }
        defer {
            if !wasEnabled {
                metrics.setEnabled(false)
            }
        }
        let before = metrics.snapshot()
        // No suspension: other MainActor clients cannot enter this measurement.
        for _ in 0..<1_000 {
            _ = service.windows
            _ = service.sessions
            _ = service.session(named: "files")
        }
        let after = metrics.snapshot()
        #expect((after.timings[.windowGrouping]?.count ?? 0) - (before.timings[.windowGrouping]?.count ?? 0) == 1)
        #expect((after.timings[.sessionGrouping]?.count ?? 0) - (before.timings[.sessionGrouping]?.count ?? 0) == 1)
    }

    private nonisolated func row(name: String, width: Int) -> String {
        ["%1", name, "0", "0", "zsh", "/repo", String(width), "24", "1", "", "", "main", "1"].joined(separator: String(PaneInfo.fieldSeparator))
    }
}
