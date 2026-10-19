#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    struct PaneLinkedTabTitleSwipe: ViewModifier {
        let selected: PaneLinkedTabID?
        let onSwitch: (PaneLinkedTabID, Int) -> Void
        @State private var start: PaneLinkedTabID?

        func body(content: Content) -> some View {
            content.highPriorityGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { _ in
                        if start == nil {
                            start = selected
                        }
                    }
                    .onEnded { value in
                        defer { start = nil }
                        let translation = CGPoint(x: value.translation.width, y: value.translation.height)
                        guard
                            let start, start == selected,
                            let direction = TerminalWindowSwipePolicy.direction(translation: translation),
                            TerminalWindowSwipePolicy.shouldSwitch(translation: translation, startedDirection: direction) else { return }
                        onSwitch(start, direction == .next ? 1 : -1)
                    },
                including: selected == nil ? .none : .all
            )
            .onChange(of: selected) { start = nil }
        }
    }
#endif
