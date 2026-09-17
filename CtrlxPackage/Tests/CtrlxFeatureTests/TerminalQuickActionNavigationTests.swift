#if os(iOS)
    import CtrlxCommon
    import CtrlxNetworking
    import Dependencies
    import Observation
    import SwiftUI
    import UIKit
    import XCTest
    @testable import CtrlxFeature

    /// Must run with an iOS application host. Pure presentation-state tests
    /// cannot catch an overlay inserting a nested UIKit navigation controller.
    @MainActor
    final class TerminalQuickActionNavigationTests: XCTestCase {
        func testPanelsDoNotPopSessionOrMoveTerminal() async throws {
            let fixture = try NavigationFixture()
            let window = try makeWindow(fixture)
            defer { window.isHidden = true }
            await settle(window)
            fixture.path = ["session"]
            await settle(window)
            let frame = fixture.terminalFrame
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertEqual(navigationControllerCount(window.rootViewController), 1)
            let appearances = fixture.terminalAppearances

            // Exercise insertion, replacement and removal inside the SAME
            // NavigationStack as the session route, not a standalone sheet.
            for _ in 0 ..< 2 {
                for panel in [TerminalQuickActionPresentation.Panel.commands(fixture.command), .phrases(fixture.phrase)] {
                    fixture.presentation.toggle(panel)
                    await settle(window)
                    XCTAssertEqual(fixture.path, ["session"])
                    XCTAssertTrue(fixture.presentation.isPresented)
                    XCTAssertEqual(navigationControllerCount(window.rootViewController), 1)
                    XCTAssertEqual(fixture.terminalFrame, frame)
                    XCTAssertEqual(fixture.terminalAppearances, appearances)
                    XCTAssertEqual(fixture.terminalDisappearances, 0)
                }
                // The last open panel is phrases: repeat its toolbar action.
                fixture.presentation.toggle(.phrases(fixture.phrase))
                await settle(window)
                XCTAssertEqual(fixture.path, ["session"])
                XCTAssertEqual(fixture.terminalFrame, frame)
                XCTAssertEqual(fixture.terminalDisappearances, 0)
            }
        }

        func testPhraseEditorStaysInsideOverlay() async throws {
            let fixture = try NavigationFixture()
            let window = try makeWindow(fixture)
            defer { window.endEditing(true); window.isHidden = true }
            await settle(window)
            fixture.path = ["session"]
            await settle(window)
            fixture.presentation.show(.phrases(fixture.phrase))
            await settle(window)
            fixture.presentation.isEditingPhrase = true
            await settle(window)
            XCTAssertEqual(fixture.path, ["session"])
            XCTAssertEqual(navigationControllerCount(window.rootViewController), 1)
            fixture.presentation.isEditingPhrase = false
            await settle(window)
            XCTAssertEqual(fixture.path, ["session"])
            XCTAssertTrue(fixture.presentation.isPresented)
            fixture.presentation.isEditingPhrase = true
            await settle(window)
            fixture.presentation.toggle(.phrases(fixture.phrase))
            await settle(window)
            XCTAssertFalse(fixture.presentation.isPresented)
            XCTAssertFalse(fixture.presentation.suspendsTerminalInput)
            XCTAssertEqual(fixture.path, ["session"])
            XCTAssertEqual(fixture.terminalDisappearances, 0)
            XCTAssertTrue(fixture.store.phrases.isEmpty)
        }

        private func makeWindow(_ fixture: NavigationFixture) throws -> UIWindow {
            let app = UIApplication.perform(#selector(getter: UIApplication.shared))?.takeUnretainedValue() as? UIApplication
            let scene = try XCTUnwrap(app?.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                     "Run this regression test with an iOS application host.")
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: NavigationHarness(fixture: fixture))
            window.makeKeyAndVisible()
            return window
        }

        private func settle(_ window: UIWindow) async {
            // Allow SwiftUI reconciliation and the native push/pop transition
            // to finish before checking controller containment and geometry.
            try? await Task.sleep(for: .milliseconds(400))
            window.rootViewController?.view.layoutIfNeeded()
        }

        private func navigationControllerCount(_ controller: UIViewController?) -> Int {
            guard let controller else { return 0 }
            return (controller is UINavigationController ? 1 : 0)
                + controller.children.reduce(0) { $0 + navigationControllerCount($1) }
        }
    }

    @Observable
    @MainActor
    private final class NavigationFixture {
        var path: [String] = []
        var presentation = TerminalQuickActionPresentation()
        var terminalFrame = CGRect.zero
        var terminalAppearances = 0
        var terminalDisappearances = 0
        let store: QuickPhraseStore
        let phrase = TerminalPhraseContext(hostID: "test", paneID: "%1", inputRevision: 0,
                                           isConnected: true, isInputAvailable: true)
        let command: AgentCommandContext

        init() throws {
            store = withDependencies { $0[PreferencesService.self] = .inMemory() } operation: { QuickPhraseStore() }
            command = try XCTUnwrap(AgentCommandContext(
                hostID: "test", paneID: "%1", session: AgentSession(paneId: "%1", pluginID: "codex"),
                isConnected: true, isInputAvailable: true, hasExternalEditor: false, inputRevision: 0
            ))
        }
    }

    @MainActor
    private struct NavigationHarness: View {
        @Bindable var fixture: NavigationFixture

        var body: some View {
            NavigationStack(path: $fixture.path) {
                Text("Sessions")
                    .navigationDestination(for: String.self) { _ in
                        Color.black
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                fixture.terminalFrame = $0
                            }
                            .onAppear { fixture.terminalAppearances += 1 }
                            .onDisappear { fixture.terminalDisappearances += 1 }
                            .modifier(TerminalQuickActionOverlay(
                                presentation: $fixture.presentation, store: fixture.store,
                                phraseContext: fixture.phrase, sendPhrase: { _ in false },
                                commandContext: fixture.command, sendCommand: { _ in false }
                            ))
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                Text("Keyboard row").frame(height: 36)
                            }
                            .navigationTitle("Session")
                    }
            }
        }
    }
#endif
