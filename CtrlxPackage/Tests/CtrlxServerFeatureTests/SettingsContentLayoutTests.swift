import AppKit
import CtrlxCommon
import CtrlxEncryption
import Dependencies
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct SettingsContentLayoutTests {
    @Test("Switching to Sidebar and Editors keeps the navigation and detail inside the Settings window")
    func switchingPagesKeepsLayoutBounded() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
        } operation: {
            _ = NSApplication.shared
            let coordinator = AppCoordinator()
            coordinator.settings.selectedSettingsTab = .appearance
            let host = NSHostingView(rootView: SettingsView()
                .environment(coordinator)
                .environment(coordinator.settings))
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: 900, height: 600),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }

            for size in [CGSize(width: 900, height: 600), CGSize(width: 1_100, height: 700)] {
                window.setContentSize(size)
                for tab in [SettingsTab.appearance, .browser, .sidebarLayout, .editors, .appearance, .sidebarLayout] {
                    coordinator.settings.selectedSettingsTab = tab
                    try await Task.sleep(for: .milliseconds(100))
                    host.layoutSubtreeIfNeeded()
                    // Previously Sidebar raised the minimum height to 1472 pt,
                    // centering the entire navigation above the visible window.
                    #expect(host.fittingSize.height <= host.bounds.height)
                    let split = try #require(splitView(in: host))
                    let frame = split.convert(split.bounds, to: host)
                    #expect(frame.minY >= -1)
                    #expect(frame.maxY <= host.bounds.maxY + 1)
                }
            }
        }
    }

    private func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView {
            return split
        }
        return view.subviews.lazy.compactMap { splitView(in: $0) }.first
    }
}
