import SwiftUI

/// Keep the title compact so the toolbar's empty area retains native window gestures.
struct WorkbenchWindowTitle: ToolbarContent {
    let title: String

    var body: some ToolbarContent {
        if #available(macOS 26.1, *) {
            titleItem
                .sharedBackgroundVisibility(.hidden)
                .visibilityPriority(.low)
        } else if #available(macOS 26.0, *) {
            titleItem.sharedBackgroundVisibility(.hidden)
        } else {
            titleItem
        }
        ToolbarItem(placement: .automatic) {
            Spacer()
        }
    }

    private var titleItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240, alignment: .leading)
                .help(title)
                .allowsHitTesting(false)
        }
    }
}
