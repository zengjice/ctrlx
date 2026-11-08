#if os(iOS)
    import CtrlxCommon
    import SwiftUI
    import UIKit

    struct ResourceTabNavigationBar: View {
        let sourceName: String?
        let isAgentSource: Bool
        let isEnabled: Bool
        let onAction: (ResourceTabNavigationPolicy.Action) -> Void

        var body: some View {
            VStack(spacing: 0) {
                Capsule()
                    .fill(.secondary.opacity(0.5))
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .accessibilityHidden(true)
                navigationButtons
                HStack(spacing: 6) {
                    Symbols.chevronLeft2.image
                    Capsule()
                        .frame(width: 52, height: 3)
                    Symbols.chevronRight2.image
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.5))
                .frame(width: 96, height: 12)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            }
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .contentShape(Rectangle())
            .gesture(ResourceTabNavigationGesture(isEnabled: isEnabled, onAction: onAction))
        }

        private var navigationButtons: some View {
            HStack(spacing: 16) {
                Button { onAction(sourceName == nil ? .tabs : .source) } label: {
                    HStack(spacing: 8) {
                        if let sourceName {
                            LinkedTabSourceIcon(isAgentSource: isAgentSource)
                            Text(sourceName).lineLimit(1).truncationMode(.middle)
                        } else {
                            Label("Tabs", symbol: .chevronUp)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(sourceName.map { "Return to \($0)" } ?? "Show Tabs")
                .accessibilityHint(sourceName == nil ? "Swipe left or right to switch tabs. Swipe up to show tabs." : "Swipe left or right to switch within this group. Swipe up to show tabs.")
                .accessibilityIdentifier("resource-navigation-source")
                .accessibilityActions {
                    Button(sourceName == nil ? "Previous Tab" : "Previous Tab in Group") { onAction(.previous) }
                    Button(sourceName == nil ? "Next Tab" : "Next Tab in Group") { onAction(.next) }
                }
                .disabled(!isEnabled)
                if sourceName != nil {
                    Button { onAction(.tabs) } label: {
                        Label("Tabs", symbol: .chevronUp).frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("resource-navigation-tabs")
                    .disabled(!isEnabled)
                }
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .padding(.horizontal, 16)
        }
    }

    /// Only the bottom bar owns this recognizer; content touches never reach it.
    struct ResourceTabNavigationGesture: UIGestureRecognizerRepresentable {
        let isEnabled: Bool
        let onAction: (ResourceTabNavigationPolicy.Action) -> Void

        func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
            Coordinator()
        }

        func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
            let recognizer = UIPanGestureRecognizer()
            recognizer.maximumNumberOfTouches = 1
            recognizer.cancelsTouchesInView = true
            recognizer.delaysTouchesBegan = false
            recognizer.delegate = context.coordinator
            updateUIGestureRecognizer(recognizer, context: context)
            return recognizer
        }

        func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
            context.coordinator.onAction = onAction
            // Keep consuming bar drags while editing, including system content Back.
            context.coordinator.isEnabled = isEnabled
        }

        func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
            context.coordinator.handle(recognizer)
        }

        @MainActor
        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var isEnabled = false {
                didSet {
                    if !isEnabled {
                        pending = nil
                    }
                }
            }

            var onAction: (ResourceTabNavigationPolicy.Action) -> Void = { _ in }
            private var startLocation = CGPoint.zero
            private var pending: (action: ResourceTabNavigationPolicy.Action, send: (ResourceTabNavigationPolicy.Action) -> Void)?

            func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
                pending = nil
                // Preserve the system Back gesture at the leading edge.
                guard let window = gestureRecognizer.view?.window else { return false }
                startLocation = touch.location(in: window)
                return startLocation.x - window.bounds.minX > 32
            }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
                let action = ResourceTabNavigationPolicy.start(translation: translation(pan))
                pending = isEnabled ? action.map { ($0, onAction) } : nil
                // Even an unsupported drag must cancel the button under the finger.
                return true
            }

            private func translation(_ pan: UIPanGestureRecognizer) -> CGPoint {
                // SwiftUI can reset the recognizer's translation before shouldBegin.
                let point = pan.location(in: pan.view?.window)
                return CGPoint(x: point.x - startLocation.x, y: point.y - startLocation.y)
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
            ) -> Bool {
                guard #available(iOS 26.0, *) else { return false }
                var responder: UIResponder? = gestureRecognizer.view
                while let current = responder {
                    if let controller = current as? UIViewController, let navigation = controller.navigationController {
                        return otherGestureRecognizer === navigation.interactiveContentPopGestureRecognizer
                    }
                    responder = current.next
                }
                return false
            }

            func handle(_ recognizer: UIPanGestureRecognizer) {
                switch recognizer.state {
                case .ended:
                    defer { pending = nil }
                    guard
                        isEnabled, let pending,
                        ResourceTabNavigationPolicy.completes(translation: translation(recognizer), action: pending.action) else { return }
                    pending.send(pending.action)
                case .cancelled,
                     .failed: pending = nil
                default: break
                }
            }
        }
    }
#endif
