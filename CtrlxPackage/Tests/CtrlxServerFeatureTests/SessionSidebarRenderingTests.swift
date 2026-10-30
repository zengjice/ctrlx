import AppKit
import CtrlxCommon
import CtrlxEncryption
import CtrlxNetworking
import Dependencies
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct SessionSidebarRenderingTests {
    @Test("Comparable rows retain live fields, progress and theme updates", arguments: [false, true])
    func liveRow(remote: Bool) async throws {
        try await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[SecretsService.self] = .inMemory()
        } operation: {
            _ = NSApplication.shared
            NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
            let settings = AppSettings()
            settings.theme = .defaultDark
            settings.sidebarFields = [.sessionName]
            let state = RowState(data: data(title: "First description", progress: 40, remote: remote))
            let host = NSHostingView(rootView: RowFixture(state: state, remote: remote).environment(settings).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            NSApp.setActivationPolicy(.accessory)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            defer { window.close() }
            _ = try await element(in: host, label: "work")
            settings.sidebarFields = [.customDescription]
            _ = try await element(in: host, label: "First description")
            state.data = data(title: "Changed description", progress: 70, remote: remote)
            _ = try await element(in: host, label: "Changed description")
            let progress = try await element(in: host, label: "Terminal progress")
            #expect(attribute("accessibilityValue", from: progress) as? String == "70%")
            try await Task.sleep(for: .milliseconds(400))
            let dark = try bitmap(host)
            // Default themes both use semantic .primary. Codex Light changes the row's explicit color.
            settings.theme = .codexLight
            try await Task.sleep(for: .milliseconds(100))
            #expect(try bitmap(host) != dark)
        }
    }

    private func data(title: String, progress: Int, remote: Bool) -> SessionSidebarData {
        let state = PaneState(paneId: "%1", sessionName: "work", customDescription: title, agentSession: .init(paneId: "%1", state: .idle), progress: .normal(progress))
        if remote {
            return .init(session: TmuxSession.groupWindows(TmuxWindow.groupPanes([state]))[0])
        }
        let pane = PaneInfo(paneId: "%1", target: "work:0.0", sessionName: "work", windowIndex: 0, paneIndex: 0, command: "zsh", currentPath: "/repo", width: 80, height: 24, isActive: true)
        let session = LocalTmuxSession.groupWindows(LocalTmuxWindow.groupPanes([pane]))[0]
        return .init(session: session, paneStates: ["%1": state], includeTelemetry: false)
    }

    private func bitmap(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func element(in view: NSView, label: String) async throws -> NSObject {
        var observed: Set<String> = []
        for _ in 0..<100 {
            var queue: [Any] = [view]
            var visited: Set<ObjectIdentifier> = []
            var combined: NSObject?
            while !queue.isEmpty {
                guard let node = queue.removeFirst() as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { continue }
                let values = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { attribute($0, from: node) as? String }
                observed.formUnion(values)
                if values.contains(label) {
                    return node
                }
                if combined == nil, values.contains(where: { $0.contains(label) }) {
                    combined = node
                }
                queue += attribute("accessibilityChildren", from: node) as? [Any] ?? []
                if let node = node as? NSView {
                    queue += node.subviews
                }
            }
            if let combined {
                return combined
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "SessionSidebarRenderingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(label); observed: \(observed.sorted())"])
    }

    private func attribute(_ name: String, from node: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }
}

@Observable
@MainActor
final private class RowState {
    var data: SessionSidebarData
    init(data: SessionSidebarData) {
        self.data = data
    }
}

private struct RowFixture: View {
    let state: RowState
    let remote: Bool
    var body: some View {
        Button { } label: {
            if remote {
                RemoteSessionSidebarRow(data: state.data).equatable()
            } else {
                SessionSidebarRow(data: state.data).equatable()
            }
        }
        .buttonStyle(.plain)
        .accessibilityChildren { SessionProgressAccessibilityProxy(progress: state.data.progress) }
    }
}
