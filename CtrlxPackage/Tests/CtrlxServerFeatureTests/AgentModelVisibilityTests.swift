import AppKit
import Testing
@testable import CtrlxServerFeature

@MainActor
struct AgentModelVisibilityTests {
    @Test("Occluded windows pause reads; visible windows resume without keyboard focus")
    func windowVisibility() async {
        _ = NSApplication.shared
        let window = VisibilityWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = AgentModelVisibility.Anchor()
        defer { anchor.stop()
            window.close()
        }
        let mounted = await visibility(of: anchor) { window.contentView?.addSubview(anchor) }
        #expect(!mounted)
        #expect(!window.isKeyWindow)
        let visible = await visibility(of: anchor) {
            window.showsContent = true
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        #expect(visible)
        let minimized = await visibility(of: anchor) {
            window.showsContent = false
            NotificationCenter.default.post(name: NSWindow.didMiniaturizeNotification, object: window)
        }
        #expect(!minimized)
        let restored = await visibility(of: anchor) {
            window.showsContent = true
            NotificationCenter.default.post(name: NSWindow.didDeminiaturizeNotification, object: window)
        }
        #expect(restored)
        let detached = await visibility(of: anchor) { anchor.removeFromSuperview() }
        #expect(!detached)
    }

    @Test("Visibility probe does not intercept status-bar clicks")
    func clickThrough() {
        let anchor = AgentModelVisibility.Anchor(frame: CGRect(x: 0, y: 0, width: 500, height: 32))
        #expect(anchor.hitTest(CGPoint(x: 20, y: 20)) == nil)
        anchor.stop()
    }

    private func visibility(of anchor: AgentModelVisibility.Anchor, action: () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            anchor.visibilityChanged = { value in
                anchor.visibilityChanged = nil
                continuation.resume(returning: value)
            }
            action()
        }
    }

    final private class VisibilityWindow: NSWindow {
        var showsContent = false
        override var occlusionState: OcclusionState {
            showsContent ? [.visible] : []
        }
    }
}
