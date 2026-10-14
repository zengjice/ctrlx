import SwiftUI

/// Standard menu routing keeps shortcuts in the active workbench scene.
public struct WorkbenchKeyboardCommands: Commands {
    private let settings: AppSettings
    @FocusedValue(\.workbenchMenuActions) private var actions

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { actions?.newLocalSession?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(actions?.newLocalSession == nil)
            Button("New Terminal") { actions?.newTerminal?() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(actions?.newTerminal == nil)
        }
        CommandGroup(before: .windowList) {
            Button("Switch Session…") { actions?.switchSession?() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(actions?.switchSession == nil)
            Button("Previous Session") { actions?.selectPreviousSession?() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(actions?.selectPreviousSession == nil)
            Button("Next Session") { actions?.selectNextSession?() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(actions?.selectNextSession == nil)
            Divider()
            Button("Previous Tab") { actions?.selectPreviousTab() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled((actions?.tabCount ?? 0) < 2)
            Button("Next Tab") { actions?.selectNextTab() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled((actions?.tabCount ?? 0) < 2)
            Menu("Select Tab") {
                ForEach(0..<9, id: \.self) { index in
                    Button("Tab \(index + 1)") { actions?.selectTabAtIndex(index) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        .disabled(index >= (actions?.tabCount ?? 0))
                }
            }
            .disabled((actions?.tabCount ?? 0) == 0)
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Files…") { actions?.openContentSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(actions == nil)
            Button("Start / Stop Voice Input") { actions?.toggleVoiceInput?() }
                .keyboardShortcut("m", modifiers: [.command, .option])
                .disabled(actions?.toggleVoiceInput == nil)
        }
        CommandGroup(replacing: .toolbar) {
            Button("Increase Font Size") { settings.increaseFontSize() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Decrease Font Size") { settings.decreaseFontSize() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Font Size") { settings.resetFontSize() }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Refresh Sessions") {
                NotificationCenter.default.post(name: .refreshPaneList, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)
            Divider()
            Toggle("Show Status Bar", isOn: Bindable(settings).showStatusBar)
                .keyboardShortcut("s", modifiers: [.command, .option])
        }
    }
}
