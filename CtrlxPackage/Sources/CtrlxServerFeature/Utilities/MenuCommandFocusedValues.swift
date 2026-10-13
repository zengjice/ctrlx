import SwiftUI

/// Menu actions belong to the key workbench, never every open MainView.
public struct WorkbenchMenuActions {
    public var openContentSearch: @MainActor () -> Void
    public var selectPreviousTab: @MainActor () -> Void
    public var selectNextTab: @MainActor () -> Void
    public var selectPreviousSession: (@MainActor () -> Void)?
    public var selectNextSession: (@MainActor () -> Void)?
    public var newLocalSession: (@MainActor () -> Void)?
}

public struct WorkbenchMenuActionsKey: FocusedValueKey {
    public typealias Value = WorkbenchMenuActions
}

public extension FocusedValues {
    var workbenchMenuActions: WorkbenchMenuActions? {
        get { self[WorkbenchMenuActionsKey.self] }
        set { self[WorkbenchMenuActionsKey.self] = newValue }
    }
}

/// Focused-scene action for closing the currently-active tab in the panes
/// window. Set by `MainView.focusedSceneValue` so the global Cmd-W menu
/// item routes to the tab-close logic only when the panes scene is the
/// focused scene. Other scenes (Settings, About, CLI API Reference) don't
/// set this value, so the menu item falls back to `performClose:` against
/// the key window and closes them instead.
public struct CloseCurrentTabActionKey: FocusedValueKey {
    public typealias Value = @MainActor () -> Void
}

public extension FocusedValues {
    var closeCurrentTabAction: CloseCurrentTabActionKey.Value? {
        get { self[CloseCurrentTabActionKey.self] }
        set { self[CloseCurrentTabActionKey.self] = newValue }
    }
}

/// Scene-local terminal-window navigation exposed to the macOS Window menu.
/// Keeping the actions in focused values makes menu shortcuts target only the
/// active panes scene; terminal views never need to intercept the key events.
public struct TerminalWindowNavigationActions {
    public let windowCount: Int
    public let selectPrevious: @MainActor () -> Void
    public let selectNext: @MainActor () -> Void
    public let selectAtIndex: @MainActor (Int) -> Void

    public init(
        windowCount: Int,
        selectPrevious: @escaping @MainActor () -> Void,
        selectNext: @escaping @MainActor () -> Void,
        selectAtIndex: @escaping @MainActor (Int) -> Void
    ) {
        self.windowCount = windowCount
        self.selectPrevious = selectPrevious
        self.selectNext = selectNext
        self.selectAtIndex = selectAtIndex
    }
}

public struct TerminalWindowNavigationActionsKey: FocusedValueKey {
    public typealias Value = TerminalWindowNavigationActions
}

public extension FocusedValues {
    var terminalWindowNavigationActions: TerminalWindowNavigationActions? {
        get { self[TerminalWindowNavigationActionsKey.self] }
        set { self[TerminalWindowNavigationActionsKey.self] = newValue }
    }
}
