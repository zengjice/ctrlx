import AppKit
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite("Mac quick-action layout")
struct TerminalQuickActionLayoutTests {
    @Test(
        "Controls fit narrow proposals and retain their height when focus moves",
        arguments: [84.0, 199.0, 900.0],
        [false, true]
    )
    func adaptiveControls(width: Double, remote: Bool) throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            let coordinator = AppCoordinator()
            let router = TerminalQuickActionRouter()
            let hostID = remote ? "office" : nil
            let endpoint = TerminalQuickActionEndpoint(
                hostID: hostID, paneID: "%1", isVisible: { true }, enqueue: { _ in }
            )
            router.focus(endpoint)
            let measurements = Measurements()
            // 199 points is the content width of the reported 223-point split;
            // 84 leaves room for the adjacent session identifier as well.
            for ownsFocus in [true, false] {
                let view = TerminalQuickActionStatusBarButtons(
                    hostID: hostID, paneIDs: ownsFocus ? ["%1"] : ["%2"]
                )
                .environment(\.terminalQuickActions, router)
                .environment(coordinator)
                .environment(coordinator.settings)
                .environment(coordinator.windowManager)
                .environment(coordinator.editorSessionManager)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { measurements.size = $0 }
                let host = NSHostingView(rootView: view)
                host.sizingOptions = []
                host.frame = CGRect(x: 0, y: 0, width: width, height: 32)
                host.layoutSubtreeIfNeeded()
                let size = try #require(measurements.size)
                #expect(size.width <= width)
                #expect(size.width >= 64)
                #expect(size.height == 32)
                measurements.size = nil
            }
        }
    }

    @Test(
        "Complete status bars and terminal viewports stay inside both workbench splits",
        arguments: [0.15, 0.25, 0.5, 0.75, 0.85],
        [false, true]
    )
    func completeSplitLayout(ratio: Double, remote: Bool) throws {
        try withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            let coordinator = AppCoordinator()
            let router = TerminalQuickActionRouter()
            let hostID = remote ? "office" : nil
            let tabs = SessionFileTabsState()
            tabs.splitRatio = ratio
            let measurements = Measurements()
            let telemetry = SessionTelemetry(tokensUsed: 33_700, lastTurnLatencyMs: 4_800, model: "gpt-6-astra")

            for name in ["ctrlx", String(repeating: "long-session-name-", count: 8)] {
                for hasTelemetry in [false, true] {
                    for focusedPane in ["%1", "%2"] {
                        router.focus(TerminalQuickActionEndpoint(
                            hostID: hostID, paneID: focusedPane, isVisible: { true }, enqueue: { _ in }
                        ))
                        func pane(_ id: String) -> some View {
                            VStack(spacing: 0) {
                                // A viewport with no tmux connection: exercise the same sizing
                                // proposal the status bar passes to its terminal sibling.
                                Color.clear
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: {
                                        measurements.frames["\(id)-terminal"] = $0
                                    }
                                TerminalWindowStatusBar(
                                    hostID: hostID, paneIDs: [id], sessionName: name, windowIndex: 1,
                                    terminalSize: "175x59", telemetry: hasTelemetry ? telemetry : nil,
                                    permissionMode: hasTelemetry ? "bypassPermissions" : nil
                                )
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("workspace")) } action: {
                                    measurements.frames["\(id)-bar"] = $0
                                }
                            }
                        }
                        let view = SplitDetailContent(sessionTabs: tabs) {
                            pane("%1")
                        } right: {
                            pane("%2")
                        }
                        .coordinateSpace(name: "workspace")
                        .environment(\.terminalQuickActions, router)
                        .environment(coordinator)
                        .environment(coordinator.settings)
                        .environment(coordinator.windowManager)
                        .environment(coordinator.editorSessionManager)
                        let host = NSHostingView(rootView: view)
                        host.sizingOptions = []
                        host.frame = CGRect(x: 0, y: 0, width: 900, height: 200)
                        host.layoutSubtreeIfNeeded()

                        for id in ["%1", "%2"] {
                            let bar = try #require(measurements.frames["\(id)-bar"])
                            let terminal = try #require(measurements.frames["\(id)-terminal"])
                            let width = 900 * (id == "%1" ? ratio : 1 - ratio) - SplitLayout.dividerWidth / 2
                            #expect(abs(bar.width - width) < 1)
                            #expect(abs(terminal.width - width) < 1)
                            #expect(bar.minX >= 0 && bar.maxX <= 900)
                            #expect(terminal.minX >= 0 && terminal.maxX <= 900)
                            #expect(bar.height == 44)
                            #expect(terminal.height == 156)
                        }
                        measurements.frames.removeAll()
                    }
                }
            }
        }
    }

    final private class Measurements {
        var size: CGSize?
        var frames: [String: CGRect] = [:]
    }
}
