import AppKit
import Observation
import SwiftUI
import Synchronization

@MainActor
final class PromptTestApplication: NSApplication {
    var foregroundForTest = false
    override var isActive: Bool {
        foregroundForTest
    }
}

struct PromptTestApp: App {
    @NSApplicationDelegateAdaptor(PromptTestDelegate.self) private var delegate
    @State private var settings = AppSettings()
    @State private var integration = IPAFileIntegration()
    @State private var runner = PromptTestRunner()

    var body: some Scene {
        IPADefaultApplicationPromptScene(settings: settings)
        Window("Fixture Main", id: "fixture-main") {
            PromptTestRoot(runner: runner, integration: integration, settings: settings)
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
    }
}

private struct PromptTestRoot: View {
    let runner: PromptTestRunner
    let integration: IPAFileIntegration
    let settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Main Action") { runner.mainActions += 1 }
            .frame(width: 600, height: 400)
            .suggestDefaultIPAApplication(integration, isReady: true)
            .environment(settings)
            .task {
                do {
                    try await runner.run(integration: integration, settings: settings) { value in
                        openWindow(id: IPADefaultApplicationPromptScene.windowID, value: value)
                    }
                } catch {
                    print("FAIL: \(error)")
                    exit(1)
                }
            }
    }
}

@MainActor
final class PromptTestDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        print("PASS: normal quit while reminder remains open")
        return .terminateNow
    }
}

@MainActor @Observable
private final class PromptTestRunner {
    var mainActions = 0

    func run(integration: IPAFileIntegration, settings: AppSettings, open: (String) -> Void) async throws {
        NSApp.setActivationPolicy(.prohibited)
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let app = try require(NSApp as? PromptTestApplication, "fixture application")
        try await wait { integration.defaultApplicationPrompt != nil }
        try check(!NSApp.windows.contains { $0.title == "IPA Files" && $0.isVisible }, "background startup opened a reminder")
        app.foregroundForTest = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
        let prompt = try await window("IPA Files")
        let main = try await window("Fixture Main")
        print("PASS: background deferral and foreground presentation")
        try check(prompt.sheetParent == nil && main.attachedSheet == nil && NSApp.modalWindow == nil, "reminder is modal")
        try await press("Main Action", in: main)
        try await wait { self.mainActions == 1 }
        print("PASS: nonmodal reminder and usable main window")
        try await press("Not Now", in: prompt)
        try await wait { !prompt.isVisible }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
        try await Task.sleep(for: .milliseconds(100))
        try check(!prompt.isVisible && settings.askToHandleIPAFiles, "closed reminder reopened or changed preferences")
        print("PASS: Not Now closes once without changing preferences")

        open("Success App")
        let success = try await window("IPA Files")
        try await press("Set as Default", in: success)
        try await wait { FakeAssociation.completion != nil }
        FakeAssociation.finish()
        try await press("Done", in: success)
        try await wait { !success.isVisible }

        open("Waiting App")
        let waiting = try await window("IPA Files")
        try await press("Set as Default", in: waiting)
        try await wait { FakeAssociation.completion != nil }
        try await press("Close", in: waiting)
        try await wait { !waiting.isVisible && FakeAssociation.cancelled.withLock { $0 } }
        FakeAssociation.finish()

        open("Disabled Reminder App")
        let disabled = try await window("IPA Files")
        try await press("Don't Ask Again", in: disabled)
        try await wait { !disabled.isVisible }
        try check(!settings.askToHandleIPAFiles, "Don't Ask Again was not applied")
        print("PASS: success, cancellation and Don't Ask Again")

        open("Quit App")
        _ = try await window("IPA Files")
        try check(main.attachedSheet == nil && NSApp.modalWindow == nil, "reminder blocked normal quit")
        NSApp.terminate(nil)
    }

    private func wait(_ ready: () -> Bool) async throws {
        for _ in 0 ..< 250 {
            if ready() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FixtureError.failed("timed out waiting for fixture state")
    }

    private func window(_ title: String) async throws -> NSWindow {
        try await wait { NSApp.windows.contains { $0.title == title && $0.isVisible } }
        let window = try require(NSApp.windows.first { $0.title == title && $0.isVisible }, title)
        window.setFrameOrigin(.init(x: -10000, y: -10000))
        return window
    }

    private func press(_ label: String, in window: NSWindow) async throws {
        var found: NSObject?
        try await wait {
            var queue: [Any] = window.contentView.map { [$0] } ?? []
            var seen: Set<ObjectIdentifier> = []
            while !queue.isEmpty {
                guard let node = queue.removeFirst() as? NSObject, seen.insert(ObjectIdentifier(node)).inserted else { continue }
                if ["accessibilityLabel", "accessibilityTitle"].contains(where: { attribute($0, node) as? String == label }) {
                    found = node
                    return true
                }
                queue += attribute("accessibilityChildren", node) as? [Any] ?? []
                if let view = node as? NSView {
                    queue += view.subviews
                }
            }
            return false
        }
        let node = try require(found, label)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try require(node.method(for: selector), "button action")
        let call = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        try check(call(node, selector), "button action failed: \(label)")
    }

    private func attribute(_ name: String, _ node: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
    }
}

private enum FixtureError: Error { case failed(String) }
private func check(_ value: Bool, _ message: String) throws {
    if !value {
        throw FixtureError.failed(message)
    }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw FixtureError.failed(message) }
    return value
}

// In-memory collaborators; the real scene, presentation modifier and views are compiled unchanged.
@MainActor @Observable
public final class AppSettings { var askToHandleIPAFiles = true }
struct IPAFileAssociation: Equatable, Identifiable {
    let applicationName: String
    let isCtrlX: Bool
    var id: String {
        applicationName
    }
}

@MainActor @propertyWrapper
struct Dependency {
    let wrappedValue = IPAFileAssociationClient()
    init(_: IPAFileAssociationClient.Type) {}
}

struct Logger {
    init(label _: String) {}
    func warning(_ message: String) {
        print(message)
    }
}

enum IPAInstallerScene { static let fileWindowID = "unused" }
@MainActor
struct IPAFileAssociationClient {
    func current() throws -> IPAFileAssociation {
        .init(applicationName: "Other App", isCtrlX: false)
    }

    func setDefaultAndVerify() async throws -> IPAFileAssociation {
        FakeAssociation.cancelled.withLock { $0 = false }
        await withTaskCancellationHandler {
            await withCheckedContinuation { FakeAssociation.completion = $0 }
        } onCancel: {
            FakeAssociation.cancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()
        return .init(applicationName: "CtrlX", isCtrlX: true)
    }
}

@MainActor
private enum FakeAssociation {
    static var completion: CheckedContinuation<Void, Never>?
    nonisolated static let cancelled = Mutex(false)
    static func finish() {
        completion?.resume()
        completion = nil
    }
}
