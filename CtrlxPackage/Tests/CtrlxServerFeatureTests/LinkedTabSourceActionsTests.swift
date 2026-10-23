import Testing
@testable import CtrlxServerFeature

@MainActor
struct LinkedTabSourceActionsTests {
    @Test
    func menuActionsUseTheLinkedTabsSourcePane() throws {
        var opened: [String] = []
        let actions = LinkedTabSourceActions(
            onOpenFiles: { paneID in opened.append("files:\(paneID)") },
            onOpenBrowser: { paneID in opened.append("browser:\(paneID)") },
            onOpenSimulator: { paneID in opened.append("simulator:\(paneID)") }
        )
        let items = actions.menuItems(paneID: "%2", isSourceAvailable: true)

        #expect(items.compactMap(buttonLabel) == ["Open Files", "Open Browser", "Open iOS Simulator"])
        for item in items {
            let button = try #require(buttonAction(item))
            button()
        }
        #expect(opened == ["files:%2", "browser:%2", "simulator:%2"])
    }

    @Test
    func menuDisablesActionsWithoutAUsableSourceOrCapability() {
        let actions = LinkedTabSourceActions(
            canOpenBrowser: false,
            onOpenFiles: { _ in },
            onOpenBrowser: { _ in },
            onOpenSimulator: { _ in }
        )

        let missingSource = actions.menuItems(paneID: "%1", isSourceAvailable: false)
        #expect(missingSource.compactMap(buttonEnabled) == [false, false, false])

        let missingBrowserCapability = actions.menuItems(paneID: "%1", isSourceAvailable: true)
        #expect(missingBrowserCapability.compactMap(buttonEnabled) == [true, false, true])
    }

    private func buttonLabel(_ item: ContextMenuItem) -> String? {
        guard case let .button(title, _, _, _, _) = item else { return nil }
        return title
    }

    private func buttonEnabled(_ item: ContextMenuItem) -> Bool? {
        guard case let .button(_, _, isEnabled, _, _) = item else { return nil }
        return isEnabled
    }

    private func buttonAction(_ item: ContextMenuItem) -> (@MainActor () -> Void)? {
        guard case let .button(_, _, _, _, action) = item else { return nil }
        return action
    }
}
