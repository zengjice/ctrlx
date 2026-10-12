import CtrlxSimulatorProtocol
import Foundation
import Testing

struct SimulatorElementTests {
    private let geometry = SimulatorGeometry(width: 1179, height: 2556, scale: 3, orientation: 1,
        geometryVersion: 1, epoch: UUID().uuidString)

    @Test func referencesFollowIdentityInsteadOfOldCoordinatesOrIndices() {
        let old = SimulatorElement(index: 1, identifier: "submit", role: "AXButton", label: "Submit",
            frame: SimulatorElementFrame(x: 10, y: 20, width: 100, height: 40))
        let moved = SimulatorElement(index: 9, identifier: "submit", role: "AXButton", label: "Continue",
            frame: SimulatorElementFrame(x: 50, y: 80, width: 100, height: 40))
        #expect(old.hasSameIdentity(as: moved))
        #expect(moved.frame.visibleCenter(in: geometry) == SimulatorPoint(x: 100, y: 100))
        #expect(!old.hasSameIdentity(as: SimulatorElement(index: 1, identifier: "delete", role: "AXButton", label: "Submit",
            frame: old.frame)))
        let unnamed = SimulatorElement(index: 1, role: "AXButton", label: "Submit", frame: old.frame)
        #expect(!unnamed.hasSameIdentity(as: SimulatorElement(index: 1, role: "AXButton", label: "Delete", frame: old.frame)))
    }

    @Test func offscreenElementsDoNotProveVisibility() {
        #expect(SimulatorElementFrame(x: 400, y: 30, width: 100, height: 40).visibleCenter(in: geometry) == nil)
        #expect(SimulatorElementFrame(x: 10, y: -100, width: 100, height: 40).visibleCenter(in: geometry) == nil)
        #expect(SimulatorElementFrame(x: -50, y: 20, width: 100, height: 40).visibleCenter(in: geometry) == SimulatorPoint(x: 25, y: 40))
        #expect(SimulatorElementFrame(x: .nan, y: 20, width: 100, height: 40).visibleCenter(in: geometry) == nil)
    }

    @Test func selectorsMatchAllRequestedAttributes() throws {
        let query = try SimulatorElementQuery(identifier: "login", label: "Login", role: "AXButton")
        let frame = SimulatorElementFrame(x: 10, y: 20, width: 100, height: 40)
        #expect(query.matches(SimulatorElement(index: 1, identifier: "login", role: "AXButton", title: "Login", frame: frame)))
        #expect(!query.matches(SimulatorElement(index: 1, identifier: "login", role: "AXStaticText", label: "Login", frame: frame)))
        #expect(throws: SimulatorFailure.self) { try SimulatorElementQuery() }
        #expect(throws: SimulatorFailure.self) { try SimulatorElementQuery(identifier: "") }
    }

    @Test func swiftUIToggleUsesNativeHitPointInsteadOfLabelFrameCenter() throws {
        let data = Data("""
        {"index":6,"identifier":"swiftui.toggle","role":"AXCheckBox","subrole":"AXSwitch",
         "frame":{"x":24,"y":401.3333435058594,"width":345,"height":28},
         "visiblePoint":{"x":339.5,"y":415.3333333333333}}
        """.utf8)
        let element = try JSONDecoder().decode(SimulatorElement.self, from: data)
        #expect(element.interactionPoint(in: geometry) == SimulatorPoint(x: 339.5, y: 415.3333333333333))
        #expect(element.interactionPoint(in: geometry) != element.frame.visibleCenter(in: geometry))
        #expect(try JSONDecoder().decode(SimulatorElement.self, from: JSONEncoder().encode(element)) == element)
    }

    @Test func missingOrOffscreenNativeHitPointCannotTriggerInput() {
        let frame = SimulatorElementFrame(x: 24, y: 401, width: 345, height: 28)
        #expect(SimulatorElement(index: 1, frame: frame).interactionPoint(in: geometry) == nil)
        for point in [SimulatorPoint(x: 400, y: 415), SimulatorPoint(x: 339, y: -1),
            SimulatorPoint(x: .nan, y: 415), SimulatorPoint(x: 339, y: .infinity)] {
            #expect(SimulatorElement(index: 1, frame: frame, visiblePoint: point).interactionPoint(in: geometry) == nil)
        }
        let invalid = SimulatorGeometry(width: 1179, height: 2556, scale: 3, orientation: 0,
            geometryVersion: 1, epoch: UUID().uuidString)
        #expect(SimulatorElement(index: 1, frame: frame, visiblePoint: SimulatorPoint(x: 339, y: 415))
            .interactionPoint(in: invalid) == nil)
    }

    @Test func nativeVisibilityRejectsClippedRowsAndAllowsNoninteractiveLabels() throws {
        let data = Data("""
        {"index":4,"identifier":"swiftui.row.25","role":"AXButton",
         "frame":{"x":16,"y":13,"width":361,"height":52.33333333333334},
         "visiblePoint":{"x":-1,"y":-1},"visible":false}
        """.utf8)
        let clipped = try JSONDecoder().decode(SimulatorElement.self, from: data)
        #expect(clipped.frame.visibleCenter(in: geometry) != nil)
        #expect(!clipped.isVisible(in: geometry))
        #expect(try JSONDecoder().decode(SimulatorElement.self, from: JSONEncoder().encode(clipped)) == clipped)

        let label = SimulatorElement(index: 2, role: "AXStaticText",
            frame: SimulatorElementFrame(x: 16, y: 117, width: 87, height: 40), visible: true)
        #expect(label.isVisible(in: geometry))
        #expect(label.interactionPoint(in: geometry) == nil)
    }

    @Test func visibilityRequiresNativeMetadataAndValidScreenIntersection() throws {
        let unknown = try JSONDecoder().decode(SimulatorElement.self, from: Data("""
        {"index":1,"frame":{"x":16,"y":117,"width":87,"height":40}}
        """.utf8))
        #expect(unknown.visible == nil)
        #expect(!unknown.isVisible(in: geometry))
        for frame in [SimulatorElementFrame(x: 400, y: 30, width: 100, height: 40),
            SimulatorElementFrame(x: 16, y: 117, width: .nan, height: 40)] {
            #expect(!SimulatorElement(index: 1, frame: frame, visible: true).isVisible(in: geometry))
        }
        let invalid = SimulatorGeometry(width: 1179, height: 2556, scale: 3, orientation: 0,
            geometryVersion: 1, epoch: UUID().uuidString)
        #expect(!SimulatorElement(index: 1, frame: unknown.frame, visible: true).isVisible(in: invalid))
    }
}
