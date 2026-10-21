import AppKit
import CtrlxCommon
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct BrowserExtensionsView: View {
    let tab: AgentBrowserTabState
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [BrowserExtensionListEntry] = []
    @State private var prepared: PreparedBrowserExtension?
    @State private var busy = false
    @State private var status = ""
    @State private var errorMessage: String?
    @State private var storeLink = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Browser Extensions", symbol: .puzzlepiece).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(busy || prepared != nil)
            }
            Text("Applies to this Mac's CtrlX browser across all sessions. Use Settings below to configure an extension, or an extension window to access its toolbar button.")
                .font(.callout).foregroundStyle(.secondary)
            if let prepared {
                preview(prepared)
            } else {
                HStack {
                    TextField("Chrome Web Store link or extension ID", text: $storeLink)
                        .textFieldStyle(.roundedBorder)
                    Button("Review Install") { prepareFromStore(storeLink) }
                        .disabled(storeLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .disabled(busy)
                HStack {
                    Button("Import ZIP / CRX…") { importPackage() }
                    Button("Extension Advanced Management…") {
                        perform("Opening extension settings…") { try await tab.service.showExtensionManager(tab) }
                    }
                    Spacer()
                    Button { refresh() } label: { Label("Refresh", symbol: .arrowClockwise) }
                        .labelStyle(.iconOnly)
                }
                .disabled(busy)
                List(entries) { entry in
                    extensionRow(entry)
                        .padding(.vertical, 6)
                }
                .overlay {
                    if entries.isEmpty, !busy {
                        ContentUnavailableView("No Extensions", symbol: .puzzlepiece, description: "Paste a store link or import a ZIP / CRX package.")
                    }
                }
            }
            if busy {
                HStack { ProgressView().controlSize(.small)
                    Text(status).font(.callout)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .interactiveDismissDisabled(busy || prepared != nil)
        .task { await load() }
    }

    private func extensionRow(_ entry: BrowserExtensionListEntry) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.runtime.name).font(.headline)
                Text("\(entry.runtime.version) · \(entry.runtime.state.capitalized)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if entry.runtime.hasOptions == true {
                Button("Settings") {
                    perform("Opening extension settings…") {
                        try await tab.service.openExtensionOptions(entry.runtime, for: tab)
                    }
                }
                .disabled(!entry.runtime.isEnabled)
            }
            Button(entry.runtime.isEnabled ? "Disable" : "Enable") {
                perform("Updating extension…") {
                    try await tab.service.setExtensionEnabled(entry.runtime, enabled: !entry.runtime.isEnabled, for: tab)
                    entries = try await tab.service.browserExtensions(for: tab)
                }
            }
            if entry.canUpdate {
                Menu("Update…") {
                    Button("From ZIP / CRX…") { importPackage(replacing: entry.runtime) }
                    Button("Check Chrome Web Store") { prepareFromStore(entry.id, replacing: entry.runtime) }
                }
            }
            Button(role: .destructive) {
                perform("Confirm removal in the Chromium window…") {
                    try await tab.service.uninstallExtension(entry.runtime, for: tab)
                    entries = try await tab.service.browserExtensions(for: tab)
                }
            } label: { Label("Remove", symbol: .trash) }
                .labelStyle(.iconOnly)
        }
        .disabled(busy)
    }

    private func preview(_ package: PreparedBrowserExtension) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(package.preview.name).font(.title2)
            Text(package.replacing.map { "Update \($0.version) → \(package.preview.version)" } ?? "Version \(package.preview.version)")
            Text(sourceDescription(package.preview.source))
                .font(.callout).foregroundStyle(.secondary)
            if let previous = package.previousSource, previous != package.preview.source {
                Text("Changes source from \(sourceDescription(previous)).").font(.callout)
            }
            if package.preview.source == .webStore {
                Text("Use Update → Check Chrome Web Store for future updates.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    permissionGroup("Permissions", values: package.preview.permissions)
                    permissionGroup("Website access", values: package.preview.hostPermissions)
                    permissionGroup("Scripts on websites", values: package.preview.contentScriptMatches)
                    permissionGroup("Optional permissions", values: package.preview.optionalPermissions)
                    permissionGroup("Optional website access", values: package.preview.optionalHostPermissions)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    perform("Discarding package…") {
                        try await tab.service.cancelExtension(package)
                        prepared = nil
                    }
                }
                Button(package.replacing == nil ? "Install" : "Update") {
                    // Submission may complete after a timeout. Once attempted,
                    // the UI must refresh runtime state, never offer Cancel as rollback.
                    prepared = nil
                    perform("Installing extension…") {
                        try await tab.service.installExtension(package, for: tab)
                        entries = try await tab.service.browserExtensions(for: tab)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(busy)
        }
    }

    private func permissionGroup(_ title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(values.isEmpty ? "None" : values.joined(separator: "\n"))
                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func sourceDescription(_ source: BrowserExtensionPackagePreview.Source) -> String {
        switch source {
        case .zip: "ZIP · Unsigned package"
        case .crx: "CRX3 · Developer signature verified"
        case .webStore: "Chrome Web Store · Signed package"
        }
    }

    private func prepareFromStore(_ input: String, replacing: BrowserExtensionRuntimeItem? = nil) {
        perform("Downloading and checking store package…") {
            prepared = try await tab.service.prepareStoreExtension(input, for: tab, replacing: replacing)
        }
    }

    private func importPackage(replacing: BrowserExtensionRuntimeItem? = nil) {
        perform("Reading extension package…") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.zip, UTType(filenameExtension: "crx") ?? .data]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.message = replacing.map { "Choose a ZIP or CRX update for \($0.name)." } ?? "Choose a ZIP or CRX3 extension package."
            guard await panel.begin() == .OK, let url = panel.url else { return }
            prepared = try await tab.service.prepareExtension(file: url, for: tab, replacing: replacing)
        }
    }

    private func refresh() {
        perform("Loading extensions…") { entries = try await tab.service.browserExtensions(for: tab) }
    }

    private func load() async {
        busy = true
        status = "Loading extensions…"
        defer { busy = false }
        do { entries = try await tab.service.browserExtensions(for: tab) }
        catch { errorMessage = error.localizedDescription }
    }

    private func perform(_ status: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        self.status = status
        errorMessage = nil
        Task {
            defer { busy = false }
            do { try await action() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
