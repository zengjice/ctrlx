import AppKit
import Carbon
import CtrlxNetworking
import Dependencies
import DependenciesMacros
import Foundation

struct OrbieShortcut: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    var rawValue: String {
        "\(keyCode):\(modifiers):\(keyLabel)"
    }

    var label: String {
        [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined() + keyLabel
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(rawValue: String) {
        let fields = rawValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let key = UInt32(fields[0]), let modifiers = UInt32(fields[1]) else { return nil }
        self.init(keyCode: key, modifiers: modifiers, keyLabel: String(fields[2]))
        guard isValid else { return nil }
    }

    var isValid: Bool {
        let flags = [UInt32(controlKey), UInt32(optionKey), UInt32(shiftKey), UInt32(cmdKey)]
        let supported: Set<UInt32> = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 25, 26, 28, 29, 31, 32, 34, 35, 37, 38, 40, 45, 46, 49]
        return supported.contains(keyCode) && modifiers & ~flags.reduce(0, |) == 0
            && flags.filter { modifiers & $0 != 0 }.count >= 2
            && modifiers & UInt32(controlKey | optionKey) != 0
            && !keyLabel.isEmpty && keyLabel.utf8.count <= 16
            && !keyLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func capture(_ event: NSEvent) -> Self? {
        var modifiers: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)] {
            if event.modifierFlags.contains(flag) {
                modifiers |= UInt32(carbon)
            }
        }
        let label = event.keyCode == UInt16(kVK_Space) ? "Space" : (event.charactersIgnoringModifiers ?? "").uppercased()
        let shortcut = Self(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        return shortcut.isValid ? shortcut : nil
    }
}

@MainActor
final class OrbieHotkeyRegistration {
    private var cancellation: (() -> Void)?
    init(cancel: @escaping () -> Void) {
        self.cancellation = cancel
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}

@DependencyClient
struct OrbieHotkeyClient: Sendable {
    var register: @MainActor @Sendable (OrbieShortcut, @escaping @MainActor @Sendable () -> Void) throws -> OrbieHotkeyRegistration
}

extension OrbieHotkeyClient: DependencyKey {
    static let testValue = Self()
    static let liveValue = Self(register: { shortcut, action in
        guard shortcut.isValid else { throw AgentWorkflowError("Choose a letter, digit or Space with at least two modifiers, including Control or Option.") }
        let binding = CarbonBinding(action: action)
        try binding.install(shortcut)
        return OrbieHotkeyRegistration { binding.cancel() }
    })
}

@MainActor
final private class CarbonBinding {
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?
    let action: @MainActor @Sendable () -> Void
    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    func install(_ shortcut: OrbieShortcut) throws {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                id.signature == 0x4F726269, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let action = MainActor.assumeIsolated { Unmanaged<CarbonBinding>.fromOpaque(context).takeUnretainedValue().action }
            Task { @MainActor in action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw AgentWorkflowError("The global shortcut could not be registered. The Orbie menu remains available.") }
        let registered = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x4F726269, id: 1), GetApplicationEventTarget(), 0, &hotkey)
        guard registered == noErr else {
            cancel()
            throw AgentWorkflowError("This global shortcut is unavailable. Choose another combination; the Orbie menu remains available.")
        }
    }

    func cancel() {
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        if let hotkey {
            UnregisterEventHotKey(hotkey)
            self.hotkey = nil
        }
    }
}
