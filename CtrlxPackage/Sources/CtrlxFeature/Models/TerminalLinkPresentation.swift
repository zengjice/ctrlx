import Foundation

struct TerminalLinkPresentation {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
    }

    var item: Item?
    private(set) var suspendsTerminalInput = false

    mutating func present(_ url: URL) -> Bool {
        guard !url.isFileURL, !suspendsTerminalInput else { return false }
        item = Item(url: url)
        suspendsTerminalInput = true
        return true
    }

    mutating func didDismiss() {
        item = nil
        // The item binding clears before the sheet's dismissal animation ends.
        suspendsTerminalInput = false
    }
}
