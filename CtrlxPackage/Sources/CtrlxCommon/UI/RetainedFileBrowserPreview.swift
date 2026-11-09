#if os(macOS) || os(iOS)
    import SwiftUI

    #if os(macOS)
        @MainActor
        struct RetainedFileBrowserPreview<Content: View>: NSViewRepresentable {
            let session: FileBrowserPreviewSession
            @ViewBuilder let content: Content

            func makeNSView(context: Context) -> NSView {
                let view = NSView()
                session.mount(in: view, owner: context.coordinator.owner, environment: context.environment) { AnyView(content) }
                return view
            }

            func updateNSView(_ view: NSView, context: Context) {
                session.mount(in: view, owner: context.coordinator.owner, environment: context.environment) { AnyView(content) }
            }

            func makeCoordinator() -> Coordinator {
                Coordinator(session)
            }

            final class Coordinator {
                let owner = UUID()
                let session: FileBrowserPreviewSession
                init(_ session: FileBrowserPreviewSession) {
                    self.session = session
                }
            }

            static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
                coordinator.session.hide(owner: coordinator.owner)
                for child in view.subviews {
                    child.removeFromSuperview()
                }
            }
        }
    #else
        @MainActor
        struct RetainedFileBrowserPreview<Content: View>: UIViewControllerRepresentable {
            let session: FileBrowserPreviewSession
            @ViewBuilder let content: Content

            func makeUIViewController(context: Context) -> UIViewController {
                let view = UIViewController()
                session.mount(in: view, owner: context.coordinator.owner, environment: context.environment) { AnyView(content) }
                return view
            }

            func updateUIViewController(_ view: UIViewController, context: Context) {
                session.mount(in: view, owner: context.coordinator.owner, environment: context.environment) { AnyView(content) }
            }

            func makeCoordinator() -> Coordinator {
                Coordinator(session)
            }

            final class Coordinator {
                let owner = UUID()
                let session: FileBrowserPreviewSession
                init(_ session: FileBrowserPreviewSession) {
                    self.session = session
                }
            }

            static func dismantleUIViewController(_ view: UIViewController, coordinator: Coordinator) {
                coordinator.session.hide(owner: coordinator.owner)
                for child in view.children {
                    child.willMove(toParent: nil)
                    child.view.removeFromSuperview()
                    child.removeFromParent()
                }
            }
        }
    #endif
#endif
