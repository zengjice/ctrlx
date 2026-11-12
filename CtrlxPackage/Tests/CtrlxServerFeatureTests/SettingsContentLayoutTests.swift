import AppKit
import CtrlxCommon
import CtrlxEncryption
import CtrlxPluginProtocol
import Dependencies
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct SettingsContentLayoutTests {
    @Test("Switching Settings pages keeps navigation and detail inside the window")
    func switchingPagesKeepsLayoutBounded() async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
            $0[SimulatorSystemClient.self] = SimulatorSystemClient()
            $0[LoginItemService.self] = .previewValue
            $0[RelayCredentials.self] = .inMemory()
            $0[RelayAccessClient.self].status = { _, _, _ in .init(metered: false) }
            $0[LicensingClient.self].status = { _, _ in .init(state: .notRequired) }
        } operation: {
            @Dependency(\.self) var dependencies
            _ = NSApplication.shared
            let coordinator = AppCoordinator()
            coordinator.pluginRegistry = PluginRegistry()
            coordinator.settings.externalServerURL = "wss://settings-test.invalid"
            coordinator.settings.selectedSettingsTab = .appearance
            let encryption = E2EEService(keyPair: .generateNew())
            let pairing = PairingManager(settings: coordinator.settings, e2eeService: encryption)
            let host = NSHostingView(rootView: SettingsView()
                .environment(coordinator)
                .environment(coordinator.settings)
                .environment(coordinator.licenseManager)
                .environment(pairing)
                .environment(\.dependencies, dependencies)
                .e2eeService(encryption))
            let window = NSWindow(
                contentRect: CGRect(x: 100, y: 100, width: 900, height: 600),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }

            for size in [CGSize(width: 760, height: 520), CGSize(width: 900, height: 600), CGSize(width: 1_100, height: 700)] {
                window.setContentSize(size)
                for tab in [SettingsTab.appearance, .browser, .sidebarLayout, .editors, .agents, .relay, .remoteAccess, .remoteHosts, .about, .appearance, .sidebarLayout] {
                    coordinator.settings.selectedSettingsTab = tab
                    try await Task.sleep(for: .milliseconds(100))
                    host.layoutSubtreeIfNeeded()
                    // Previously Sidebar raised the minimum height to 1472 pt,
                    // centering the entire navigation above the visible window.
                    #expect(host.fittingSize.height <= host.bounds.height)
                    #expect(host.fittingSize.width <= host.bounds.width)
                    let split = try #require(splitView(in: host))
                    let frame = split.convert(split.bounds, to: host)
                    #expect(frame.minY >= -1)
                    #expect(frame.maxY <= host.bounds.maxY + 1)
                    if let folder = ProcessInfo.processInfo.environment["CTRLX_SETTINGS_UI_SNAPSHOTS"] {
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let png = try #require(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(tab.rawValue)-\(Int(size.width)).png"))
                    }
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
