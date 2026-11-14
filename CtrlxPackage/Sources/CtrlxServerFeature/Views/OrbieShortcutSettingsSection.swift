import AppKit
import SwiftUI

struct OrbieShortcutSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Orbie") {
            HStack {
                Text("Global shortcut")
                Spacer()
                OrbieShortcutRecorder(value: settings.orbieShortcutRaw.flatMap(OrbieShortcut.init(rawValue:))) { settings.orbieShortcutRaw = $0?.rawValue }
                    .frame(width: 200, height: 28)
                    .accessibilityIdentifier("orbie-shortcut-recorder")
                Button("Clear") { settings.orbieShortcutRaw = nil }.disabled(settings.orbieShortcutRaw == nil)
            }
            Text("Use at least two modifiers, including Control or Option, with a letter, digit or Space. No shortcut is assigned initially. Enable Orbie on this Mac to register it.")
                .font(.caption).foregroundStyle(.secondary)
            if let issue = coordinator.orbiePanel.shortcutIssue {
                Text(issue).foregroundStyle(.red)
            }
            Button("Open Orbie") { coordinator.presentOrbiePanel(openWindow: openWindow) }
        }
    }
}

private struct OrbieShortcutRecorder: NSViewRepresentable {
    let value: OrbieShortcut?
    let changed: (OrbieShortcut?) -> Void

    func makeNSView(context: Context) -> Recorder {
        let button = Recorder()
        button.target = button
        button.action = #selector(Recorder.record)
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ button: Recorder, context: Context) {
        button.value = value
        button.changed = changed
        if !button.recording {
            button.title = value?.label ?? "Record Shortcut…"
        }
    }

    final class Recorder: NSButton {
        var value: OrbieShortcut?
        var changed: ((OrbieShortcut?) -> Void)?
        var recording = false
        override var acceptsFirstResponder: Bool {
            true
        }

        @objc
        func record() {
            recording = true
            title = "Press shortcut…"
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event)
                return
            }
            if event.keyCode == 53 {
                finish()
                return
            }
            if event.keyCode == 51 {
                changed?(nil)
                value = nil
                finish()
                return
            }
            guard let shortcut = OrbieShortcut.capture(event) else { title = "Use two modifiers…"
                return
            }
            value = shortcut
            changed?(shortcut)
            finish()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        override func resignFirstResponder() -> Bool {
            finish()
            return super.resignFirstResponder()
        }

        private func finish() {
            recording = false
            title = value?.label ?? "Record Shortcut…"
        }
    }
}
