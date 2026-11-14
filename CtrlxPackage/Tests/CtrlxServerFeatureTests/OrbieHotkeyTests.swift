import AppKit
import Carbon
import CtrlxCommon
import CtrlxNetworking
import Dependencies
import Observation
import Testing
@testable import CtrlxServerFeature

@MainActor
@Suite(.serialized)
struct OrbieHotkeyTests {
    @Observable
    final class Enabled { var value = true }
    final private class Backend {
        var installed: [OrbieShortcut] = []
        var cancelled = 0
        var action: (@MainActor @Sendable () -> Void)?
        var fail = false
    }

    @Test
    func shortcutValidationDoesNotClaimCommonSingleModifierBindings() {
        let good = OrbieShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey), keyLabel: "K")
        #expect(OrbieShortcut(rawValue: good.rawValue) == good)
        #expect(good.label == "⌃⌥K")
        for modifiers in [cmdKey, controlKey, optionKey, cmdKey | shiftKey] {
            #expect(!OrbieShortcut(keyCode: good.keyCode, modifiers: UInt32(modifiers), keyLabel: "K").isValid)
        }
        for code in [kVK_Escape, kVK_Return, kVK_Delete, kVK_F1] {
            #expect(!OrbieShortcut(keyCode: UInt32(code), modifiers: good.modifiers, keyLabel: "Key").isValid)
        }
        #expect(OrbieShortcut(rawValue: "40:4352:") == nil)
        #expect(OrbieShortcut(rawValue: "garbage") == nil)
    }

    @Test
    func oneRegistrationTracksSettingAndFeatureLifetimeAndKeepsMenuOnConflict() async {
        let backend = Backend(), enabled = Enabled()
        await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[OrbieHotkeyClient.self] = .init(register: { shortcut, action in
                if backend.fail {
                    throw AgentWorkflowError("Shortcut conflict")
                }
                backend.installed.append(shortcut)
                backend.action = action
                return OrbieHotkeyRegistration { backend.cancelled += 1 }
            })
        } operation: {
            let settings = AppSettings()
            let controller = OrbiePanelController(settings: settings, enabled: { enabled.value })
            var presented = 0
            controller.start { presented += 1 }
            controller.start { presented += 1 }
            #expect(backend.installed.isEmpty)
            let first = OrbieShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey), keyLabel: "K")
            settings.orbieShortcutRaw = first.rawValue
            for _ in 0..<100 {
                await Task.yield()
            }
            #expect(backend.installed == [first])
            backend.action?()
            #expect(presented == 1)
            backend.action?()
            #expect(presented == 1 && !controller.isVisible)
            enabled.value = false
            for _ in 0..<100 {
                await Task.yield()
            }
            #expect(backend.cancelled == 1)
            backend.action?()
            #expect(presented == 1)
            backend.fail = true
            enabled.value = true
            for _ in 0..<100 {
                await Task.yield()
            }
            #expect(controller.shortcutIssue == "Shortcut conflict")
            controller.show()
            #expect(presented == 2)
            controller.stop()
            settings.orbieShortcutRaw = nil
            for _ in 0..<100 {
                await Task.yield()
            }
            #expect(backend.installed.count == 1 && backend.cancelled == 1)
        }
    }

    @Test(arguments: [NSRect(x: 0, y: 0, width: 1_440, height: 875), NSRect(x: -1_920, y: 100, width: 1_920, height: 1_080), NSRect(x: 1_440, y: -900, width: 800, height: 600)])
    func panelRemainsInsideTheChosenDisplay(visible: NSRect) {
        let frame = OrbiePanelController.frame(size: .init(width: 900, height: 700), visibleFrame: visible)
        #expect(visible.contains(frame))
        #expect(frame.midX == visible.midX && frame.midY == visible.midY)
    }
}
