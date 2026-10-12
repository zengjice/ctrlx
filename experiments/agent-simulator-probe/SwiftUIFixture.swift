import Foundation
import SwiftUI

@main
struct SwiftUIFixtureApp: App {
    var body: some Scene {
        WindowGroup {
            FixtureContent()
        }
    }
}

@MainActor
private struct FixtureContent: View {
    struct StateRecord: Encodable {
        let launchID: String
        let plain: String
        let secure: String
        let taps: Int
        let enabled: Bool
        let selectedRow: Int?
        let showingList: Bool
        let savedAt: TimeInterval
    }

    @State private var launchID = UUID().uuidString
    @State private var plain = ""
    @State private var secure = ""
    @State private var taps = 0
    @State private var enabled = false
    @State private var selectedRow: Int?
    @State private var showingList = false
    @State private var writeError: String?

    var body: some View {
        NavigationStack {
            if showingList {
                List(0..<40, id: \.self) { index in
                    Button("Row \(index)") {
                        selectedRow = index
                    }
                    .accessibilityIdentifier("swiftui.row.\(index)")
                }
                .navigationTitle("Rows")
                .toolbar {
                    Button("Close list") {
                        showingList = false
                    }
                    .accessibilityIdentifier("swiftui.close-list")
                }
            } else {
                VStack(spacing: 20) {
                    Text("Live counter \(taps)")
                        .accessibilityIdentifier("swiftui.counter")
                    Button("Tap counter") {
                        taps += 1
                    }
                    .accessibilityIdentifier("swiftui.tap")
                    .frame(minHeight: 44)
                    TextField("Plain text", text: $plain)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("swiftui.plain")
                    SecureField("Secret", text: $secure)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("swiftui.secure")
                    Toggle("Enabled", isOn: $enabled)
                        .accessibilityIdentifier("swiftui.toggle")
                    Button("Open list") {
                        showingList = true
                    }
                    .accessibilityIdentifier("swiftui.open-list")
                    if let writeError {
                        Text(writeError)
                            .accessibilityIdentifier("swiftui.write-error")
                    }
                    Spacer()
                }
                .padding(24)
                .navigationTitle("SwiftUI fixture")
            }
        }
        .task { save() }
        .onChange(of: plain) { save() }
        .onChange(of: secure) { save() }
        .onChange(of: taps) { save() }
        .onChange(of: enabled) { save() }
        .onChange(of: selectedRow) { save() }
        .onChange(of: showingList) { save() }
    }

    private func save() {
        do {
            let state = StateRecord(
                launchID: launchID,
                plain: plain,
                secure: secure,
                taps: taps,
                enabled: enabled,
                selectedRow: selectedRow,
                showingList: showingList,
                savedAt: ProcessInfo.processInfo.systemUptime)
            let data = try JSONEncoder().encode(state)
            try data.write(to: URL.documentsDirectory.appending(path: "state.json"), options: .atomic)
        } catch {
            writeError = String(describing: error)
        }
    }
}
