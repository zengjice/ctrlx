import AppKit
import SwiftUI

/// Only the symbol dependency is inert; the models and views are production code.
enum Symbols: String {
    case arrowTriangleBranch = "arrow.triangle.branch"
    case checkmark
    case minus

    var image: Image {
        Image(systemName: rawValue)
    }
}

struct WorktreeProbeIcon: View {
    let symbol: Symbols

    var body: some View {
        symbol.image.background { WorktreeProbeAnchor(id: "symbol:\(symbol.rawValue)") }
    }
}

extension Label where Title == Text, Icon == WorktreeProbeIcon {
    init(_ title: String, symbol: Symbols) {
        self.init { Text(title) } icon: { WorktreeProbeIcon(symbol: symbol) }
    }
}

struct WorktreeProbeAnchor: NSViewRepresentable {
    let id: String
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        view.identifier = .init(id)
        return view
    }

    func updateNSView(_ view: NSView, context _: Context) {
        view.identifier = .init(id)
    }
}

@MainActor @Observable
final class WorktreeFixtureState {
    var count: Int? = 123
    var repositories: [RepositoryWorktreeStatus] {
        [.init(id: "/repo/.git", worktrees: [
            .init(path: "/repo", branch: "main", pendingCommitCount: 0),
            .init(path: "/repo/feature", branch: "feature/a-long-worktree-name", pendingCommitCount: count, unavailableReason: count == nil ? "Comparison failed" : nil),
        ])]
    }
}

struct WorktreeFixture: View {
    let state: WorktreeFixtureState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorktreeStatusButton(repositories: state.repositories)
            Button("Select session") {}
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(SessionWorktreeStatusModifier(repositories: state.repositories, paths: ["/repo/feature"]))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
final class WorktreeFixtureDelegate: NSObject, NSApplicationDelegate {
    var work: Task<Void, Never>?
    let state = WorktreeFixtureState()

    func applicationDidFinishLaunching(_: Notification) {
        let hosting = NSHostingView(rootView: WorktreeFixture(state: state))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 133, height: 250), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Never activate, order front, send global events, or touch a running app.
        work = Task {
            do {
                try await settle(hosting)
                try require(find("entry", in: hosting) != nil, "repository entry missing")
                let badge = find("badge", in: hosting)
                try require(badge != nil, "pending badge missing")
                try requireSymbols([.arrowTriangleBranch, .arrowTriangleBranch], in: hosting)
                if let badge {
                    let rect = badge.convert(badge.bounds, to: hosting)
                    try require(rect.minX >= 0 && rect.maxX <= 134 && rect.width > 0, "badge overflows 133-point sidebar: \(rect)")
                }
                state.count = 0
                try await settle(hosting)
                try require(find("badge", in: hosting) != nil, "merged status button disappeared")
                try requireSymbols([.arrowTriangleBranch, .checkmark], in: hosting)
                try require(find("entry", in: hosting) != nil, "merged repository lost its list entry")
                state.count = nil
                try await settle(hosting)
                try require(find("badge", in: hosting) != nil, "unavailable comparison looked merged")
                try requireSymbols([.arrowTriangleBranch, .minus], in: hosting)
                print("PASS: narrow sidebar, separate controls, live merged and unavailable states")
                window.close()
                NSApp.terminate(nil)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
    }

    private func find(_ id: String, in view: NSView) -> NSView? {
        descendants(of: view).first { $0.identifier?.rawValue == id }
    }

    private func requireSymbols(_ symbols: [Symbols], in view: NSView) throws {
        let actual = descendants(of: view).compactMap { $0.identifier?.rawValue }.filter { $0.hasPrefix("symbol:") }.sorted()
        let expected = symbols.map { "symbol:\($0.rawValue)" }.sorted()
        try require(actual == expected, "expected icons \(expected), got \(actual)")
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw NSError(domain: "WorktreeFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

@main
struct WorktreeUIProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = WorktreeFixtureDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
