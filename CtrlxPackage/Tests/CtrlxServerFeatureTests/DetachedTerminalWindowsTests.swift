import AppKit
import CtrlxCommon
import SwiftUI
import Testing
@testable import CtrlxServerFeature

@Suite(.serialized)
@MainActor
struct DetachedTerminalWindowsTests {
    @Test
    func stableIdentityIncludesHost() throws {
        let local = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@12"))
        let remote = try #require(DetachedTerminalTarget(hostID: "host-a", windowID: "@12"))
        let another = try #require(DetachedTerminalTarget(hostID: "host-b", windowID: "@12"))
        #expect(Set([local, remote, another]).count == 3)
        #expect(DetachedTerminalTarget(hostID: nil, windowID: "session:1") == nil)
        #expect(DetachedTerminalTarget(hostID: nil, windowID: "%12") == nil)
        #expect(try JSONDecoder().decode(DetachedTerminalTarget.self, from: JSONEncoder().encode(remote)) == remote)
    }

    @Test
    func reservationIsUniqueAndCloseOnlyReleasesItsOwnPresentation() throws {
        _ = NSApplication.shared
        let state = DetachedTerminalWindows()
        let local = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@12"))
        let remote = try #require(DetachedTerminalTarget(hostID: "host-a", windowID: "@12"))
        #expect(state.reserve(local))
        #expect(!state.reserve(local))
        #expect(state.reserve(remote))
        let old = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        let current = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        state.attach(old, to: local)
        state.attach(current, to: local)
        state.didClose(local, window: old)
        #expect(state.contains(hostID: nil, windowID: "@12"))
        state.didClose(local, window: current)
        #expect(!state.contains(hostID: nil, windowID: "@12"))
        #expect(state.contains(hostID: "host-a", windowID: "@12"))
        #expect(state.reserve(local))
    }

    @Test
    func requestsCaptureSourceAndDoNotRevokeOwnership() throws {
        let state = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: "host-b", windowID: "@8"))
        state.reserve(target)
        state.request(.files(paneID: "%9"), from: target)
        let first = try #require(state.mainRequest)
        state.request(.fork(paneID: "%9", worktree: true), from: target)
        #expect(state.mainRequest?.target == target)
        #expect(state.mainRequest?.id != first.id)
        #expect(state.mainRequest?.action == .fork(paneID: "%9", worktree: true))
        #expect(state.targets == [target])
    }

    @Test
    func nativeCloseReleasesOwnershipEvenAfterContentReparenting() throws {
        _ = NSApplication.shared
        let state = DetachedTerminalWindows()
        let target = try #require(DetachedTerminalTarget(hostID: nil, windowID: "@19"))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        state.reserve(target)
        window.contentView = NSHostingView(rootView: DetachedTerminalRegistration(target: target, windows: state))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView = NSView()
        #expect(state.targets.contains(target))
        state.close(target)
        #expect(!state.targets.contains(target))
    }

    @Test
    func rightSideReturnNeverDuplicatesTheLeftRenderer() {
        let windows = [(stableID: "@1", id: "renamed:3"), (stableID: "@2", id: "renamed:7")]
        #expect(DetachedTerminalWindows.mainSelection(target: "@2", windows: windows, rightSide: ["@2"]) == "renamed:3")
        #expect(DetachedTerminalWindows.mainSelection(target: "@2", windows: windows, rightSide: []) == "renamed:7")
        #expect(DetachedTerminalWindows.mainSelection(target: "@2", windows: windows, rightSide: ["@1", "@2"]) == nil)
    }

    @Test
    func dragOriginStaysInsideItsTabEvenWhenHostingVisibleRectIsLarger() {
        let bounds = CGRect(x: 0, y: 0, width: 109, height: 25)
        let hostVisibleRect = CGRect(x: -242.5, y: -1, width: 900, height: 79)
        #expect(WindowTabDragSource.containsDragOrigin(CGPoint(x: 50, y: 12), bounds: bounds, visibleRect: hostVisibleRect))
        #expect(!WindowTabDragSource.containsDragOrigin(CGPoint(x: 150, y: 12), bounds: bounds, visibleRect: hostVisibleRect))
        #expect(!WindowTabDragSource.containsDragOrigin(CGPoint(x: -85, y: 12), bounds: bounds, visibleRect: hostVisibleRect))
        #expect(!WindowTabDragSource.containsDragOrigin(CGPoint(x: 50, y: 40), bounds: bounds, visibleRect: hostVisibleRect))

        let clipped = CGRect(x: 40, y: 0, width: 69, height: 25)
        #expect(!WindowTabDragSource.containsDragOrigin(CGPoint(x: 20, y: 12), bounds: bounds, visibleRect: clipped))
        #expect(WindowTabDragSource.containsDragOrigin(CGPoint(x: 50, y: 12), bounds: bounds, visibleRect: clipped))
    }

    @Test
    func onlyUnclaimedMouseReleaseOutsideSourceDetaches() {
        let frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let outside = CGPoint(x: 1_100, y: 400)
        #expect(WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: outside, sourceFrame: frame))
        #expect(!WindowTabDragSource.shouldDetach(operation: .move, cancelled: false, mouseReleased: true, point: outside, sourceFrame: frame))
        #expect(!WindowTabDragSource.shouldDetach(operation: [], cancelled: true, mouseReleased: true, point: outside, sourceFrame: frame))
        #expect(!WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: false, point: outside, sourceFrame: frame))
        #expect(!WindowTabDragSource.shouldDetach(operation: [], cancelled: false, mouseReleased: true, point: CGPoint(x: 110, y: 150), sourceFrame: frame))
    }

    @Test
    func draggingPayloadMatchesExistingTabDropProtocol() throws {
        let original = TabDragPayload.window("@23")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(TabDragPayload.self, from: data) == original)
    }

    @Test
    func placementSupportsNegativeScreenOrigins() {
        let display = CGRect(x: -1_600, y: 0, width: 1_600, height: 1_000)
        #expect(DetachedTerminalWindows.clampedOrigin(CGPoint(x: -1_650, y: -200), size: CGSize(width: 1_000, height: 700), visibleFrame: display) == CGPoint(x: -1_600, y: 0))
        #expect(DetachedTerminalWindows.clampedOrigin(CGPoint(x: -50, y: 900), size: CGSize(width: 1_000, height: 700), visibleFrame: display) == CGPoint(x: -1_000, y: 300))
    }
}
