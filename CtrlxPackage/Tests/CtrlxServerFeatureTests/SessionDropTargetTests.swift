#if os(macOS)
    import Foundation
    import Testing
    @testable import CtrlxServerFeature

    @Suite("Session drop target")
    struct SessionDropTargetTests {
        private let names = ["a", "b", "c"]
        private let frames = [
            "a": CGRect(x: 10, y: 10, width: 200, height: 40),
            "b": CGRect(x: 10, y: 58, width: 200, height: 80),
            "c": CGRect(x: 10, y: 146, width: 200, height: 40),
        ]

        @Test("Variable-height rows resolve distinct insertion edges")
        func insertionEdges() {
            #expect(target(x: 205, y: 60) == SessionDropTarget(sessionName: "b", insertAfter: false))
            #expect(target(x: 205, y: 135) == SessionDropTarget(sessionName: "b", insertAfter: true))
            #expect(target(x: 205, y: 170) == SessionDropTarget(sessionName: "c", insertAfter: true))
        }

        @Test("Self, out-of-group and off-sidebar positions are not destinations")
        func invalidLocations() {
            #expect(target(x: 205, y: 30) == nil)
            #expect(target(x: 5, y: 100) == nil)
            #expect(target(x: 215, y: 100) == nil)
            #expect(target(x: 100, y: -20) == nil)
            #expect(target(x: 100, y: 200) == nil)
        }

        @Test("Row spacing has a small bounded hit tolerance")
        func gaps() {
            #expect(target(x: 100, y: 56) == SessionDropTarget(sessionName: "b", insertAfter: false))
            #expect(target(x: 100, y: 140) == SessionDropTarget(sessionName: "b", insertAfter: true))
            #expect(target(x: 100, y: 189) == SessionDropTarget(sessionName: "c", insertAfter: true))
            #expect(target(x: 100, y: 192) == nil)
        }

        @Test("Removed sessions and frames from another group cannot become targets")
        func ignoresStaleFrames() {
            #expect(SessionDropTarget.resolve(
                at: CGPoint(x: 100, y: 100), sessionNames: ["a", "c"], rowFrames: frames, excluding: "a"
            ) == nil)
            #expect(SessionDropTarget.resolve(
                at: CGPoint(x: 100, y: 100), sessionNames: ["b", "c"], rowFrames: frames, excluding: "a"
            ) == nil)
            #expect(SessionDropTarget.resolve(
                at: CGPoint(x: 100, y: 100), sessionNames: names,
                rowFrames: ["a": CGRect(x: 10, y: 10, width: 200, height: 40)], excluding: "a"
            ) == nil)
        }

        @Test("Moving up or down uses the displayed order and precise edge")
        func movesByName() {
            #expect(SessionDropTarget(sessionName: "c", insertAfter: true).moving(names, source: "a") == ["b", "c", "a"])
            #expect(SessionDropTarget(sessionName: "b", insertAfter: false).moving(names, source: "c") == ["a", "c", "b"])
            #expect(SessionDropTarget(sessionName: "b", insertAfter: true).moving(names, source: "a") == ["b", "a", "c"])
        }

        @Test("Dropping in an unchanged slot or losing the source/target is a no-op")
        func ignoresNoOpMoves() {
            #expect(SessionDropTarget(sessionName: "b", insertAfter: false).moving(names, source: "a") == names)
            #expect(SessionDropTarget(sessionName: "a", insertAfter: true).moving(names, source: "b") == names)
            #expect(SessionDropTarget(sessionName: "a", insertAfter: false).moving(names, source: "a") == names)
            #expect(SessionDropTarget(sessionName: "gone", insertAfter: false).moving(names, source: "a") == names)
            #expect(SessionDropTarget(sessionName: "b", insertAfter: false).moving(names, source: "gone") == names)
        }

        @Test("Stable names are resolved again after a metadata-driven reorder")
        func resolvesFreshOrder() {
            let target = SessionDropTarget(sessionName: "b", insertAfter: false)
            #expect(target.moving(["c", "a", "b"], source: "a") == ["c", "a", "b"])
            #expect(target.moving(["b", "c", "a"], source: "a") == ["a", "b", "c"])
        }

        private func target(x: CGFloat, y: CGFloat) -> SessionDropTarget? {
            SessionDropTarget.resolve(at: CGPoint(x: x, y: y), sessionNames: names, rowFrames: frames, excluding: "a")
        }
    }
#endif
