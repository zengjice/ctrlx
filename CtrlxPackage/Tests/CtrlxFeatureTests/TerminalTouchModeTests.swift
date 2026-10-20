#if os(iOS)
    import CtrlxCommon
    import SwiftUI
    import Testing
    import UIKit
    @testable import CtrlxFeature
    @testable import SwiftTerm

    @MainActor
    @Suite("Terminal touch mode", .serialized)
    struct TerminalTouchModeTests {
        @Test("The compact accessory hides only the touch toggle")
        func defaultAccessory() throws {
            let view = InteractiveTerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 300), font: nil)
            let accessory = try #require(view.inputAccessoryView as? TerminalAccessory)
            accessory.setupUI()
            #expect(!view.allowMouseReporting)
            #expect(!accessory.configuration.showsTouchToggle)
            #expect(accessory.views.count == 9)
            #expect(accessory.views.compactMap { $0 as? UIButton }.allSatisfy {
                $0.actions(forTarget: accessory, forControlEvent: .touchDown)?
                    .contains(NSStringFromSelector(#selector(TerminalAccessory.toggleTouch(_:)))) != true
            })
        }

        @Test("Changing the pane mode updates the mounted terminal without replacing its content")
        func mountedModeChange() async throws {
            let state = TerminalState(width: 30, height: 10, fontName: "Menlo", fontSize: 10)
            state.feed(Data("touch mode preview".utf8))
            let host = UIHostingController(rootView: Self.container(state: state, mouseReporting: false))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            let view = try #require(Self.terminal(in: host.view))
            let terminal = view.getTerminal()
            #expect(!view.allowMouseReporting)
            view.setSelectionRange(start: .init(col: 0, row: 0), end: .init(col: 5, row: 0))
            let selected = try #require(view.getSelection())
            #expect(selected == "touch")

            for enabled in [true, false, true, false] {
                host.rootView = Self.container(state: state, mouseReporting: enabled)
                for _ in 0..<100 where view.allowMouseReporting != enabled {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(Self.terminal(in: host.view) === view)
                #expect(view.getTerminal() === terminal)
                #expect(view.allowMouseReporting == enabled)
                #expect(view.getSelection() == selected)
                #expect(terminal.cols == 30 && terminal.rows == 10)
                let accessory = try #require(view.inputAccessoryView as? TerminalAccessory)
                #expect(!accessory.configuration.showsTouchToggle)
            }
        }

        private static func container(state: TerminalState, mouseReporting: Bool) -> TerminalStreamContainerView {
            TerminalStreamContainerView(
                terminalState: state, theme: .defaultDark, scrollingAgentID: nil, codexQuestionID: nil,
                inputEnabled: false, mouseReportingEnabled: mouseReporting,
                keyboardRequested: false, onKeyboardRequest: nil, keyboardIsTransitioning: false,
                questionExpansionEnabled: false, onExpandCodexQuestions: { _, _ in false },
                onInput: { _ in }, onRawInput: { _ in }, onCompositionStart: { },
                onPasteText: { _ in }, onPasteImage: nil,
                onViewportGridChange: { _ in }, onInitialPresentation: { }
            )
        }

        private static func terminal(in view: UIView) -> InteractiveTerminalView? {
            if let terminal = view as? InteractiveTerminalView {
                return terminal
            }
            return view.subviews.lazy.compactMap { terminal(in: $0) }.first
        }
    }
#endif
