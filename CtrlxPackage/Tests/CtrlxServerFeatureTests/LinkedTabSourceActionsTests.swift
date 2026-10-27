import CtrlxCommon
import Testing
@testable import CtrlxServerFeature

@MainActor
struct LinkedTabSourceActionsTests {
    @Test
    func menuActionsUseTheLinkedTabsSourcePane() throws {
        var opened: [String] = []
        let actions = LinkedTabSourceActions(
            onRevealSource: { paneID in opened.append("source:\(paneID)") },
            onOpenFiles: { paneID in opened.append("files:\(paneID)") },
            onOpenBrowser: { paneID in opened.append("browser:\(paneID)") },
            onOpenSimulator: { paneID in opened.append("simulator:\(paneID)") }
        )
        let items = actions.menuItems(paneID: "%2", isSourceAvailable: true, isAgentSource: false)

        #expect(items.compactMap(buttonLabel) == ["Go to Terminal Tab", "Open Files", "Open Browser", "Open iOS Simulator"])
        for item in items {
            let button = try #require(buttonAction(item))
            button()
        }
        #expect(opened == ["source:%2", "files:%2", "browser:%2", "simulator:%2"])

        let agentItems = actions.menuItems(paneID: "%2", isSourceAvailable: true, isAgentSource: true)
        #expect(agentItems.compactMap(buttonLabel).first == "Go to Agent Tab")
    }

    @Test
    func menuDisablesActionsWithoutAUsableSourceOrCapability() {
        let actions = LinkedTabSourceActions(
            canOpenBrowser: false,
            onRevealSource: { _ in },
            onOpenFiles: { _ in },
            onOpenBrowser: { _ in },
            onOpenSimulator: { _ in }
        )

        let missingSource = actions.menuItems(paneID: "%1", isSourceAvailable: false, isAgentSource: false)
        #expect(missingSource.compactMap(buttonEnabled) == [false, false, false, false])

        let missingBrowserCapability = actions.menuItems(paneID: "%1", isSourceAvailable: true, isAgentSource: false)
        #expect(missingBrowserCapability.compactMap(buttonEnabled) == [true, true, false, true])
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
