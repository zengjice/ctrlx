import AppKit
import Observation
import SwiftUI

enum State: Equatable {
    case working, idle, awaitingPermission, awaitingReplies, awaitingPlanApproval
    case doneWorking(summary: String?)
}

struct Session { var state: State }

@MainActor @Observable final class Store {
    var value = Session(state: .working)
    var acknowledgements = 0
    func markSessionHandled(paneId _: String, hostId _: String) {
        if case .doneWorking = value.state {
            value.state = .idle
            acknowledgements += 1
        }
    }
}

struct InputBinding {
    var generation = 0
    func expectedPane(current: Self) throws {
        guard generation == current.generation else { throw failure("Retired pane") }
    }
}

struct MarkHandled {}

@MainActor final class Client {
    var workspaceInputState = InputState()
    var commands = 0
    struct InputState {
        var current = InputBinding()
        func binding(paneID _: String) -> InputBinding {
            current
        }
    }

    func sendCommand(_: MarkHandled, paneId _: String, inputBinding _: InputBinding) async {
        commands += 1
    }
}

/// Only store/transport dependencies are inert. The acknowledgement method is production code.
@MainActor final class Service {
    let sessionStore = Store()
    let relayClient = Client()
    let inputBinding = InputBinding()
    let paneId = "%fixture"
    let hostId = "fixture-host"
    var session: Session? {
        sessionStore.value
    }
    // PRODUCTION_SERVICE_METHOD
}

@MainActor @Observable final class Presentation {
    private enum TargetBinding {
        case unavailable
    }

    struct PasteCoordinator {
        var pasteError: String?
    }

    var pageVisible = true
    var terminalVisible = true
    var phase = ScenePhase.active
    var artifactPreviewIsPresented = false
    var previewFilesLink: String?
    var pendingFileLink: String?
    var windowActionsSource: String?
    var pendingWindowMenuAction: (@MainActor () -> Void)?
    var renamingWindow: String?
    var closeConfirmation: String?
    var commandError: String?
    var hookTrustMessage: String?
    var terminalLinkOrAlertPaneIDs: Set<String> = []
    typealias FileLinkActions = String
    private var fileLinkActions: FileLinkActions?
    private let linkPresentation = TerminalLinkPresentation()
    private var showsEmptySnapshotAlert = false
    var coordinator = PasteCoordinator()
    var attachmentPresentationIsActive = false
    var attachmentSelectionIsActive = false
    var isPhotoPickerPresented = false
    var isFileImporterPresented = false
    var isCameraPresented = false
    var capturedPhoto: Data?
    var preparingPhoto = false
    var isPreviewPresented = false
    var previewCoversTerminal = false
    var operationID: UUID?
    private var operationTask: Task<Void, Never>?
    private var sourceErrorMessage: String?
    var pendingBrowserLink: String?
    var request: (() -> Void)?
    var dismissPreview: (() -> Void)?
    private var targetPaneId: String?
    private var targetBinding = TargetBinding.unavailable

    private func captureTargetPane() -> Bool {
        targetPaneId = "%fixture"
        return true
    }

    private func startPreparation(_: [ImageUploadSource]) {
        preparingPhoto = true
    }

    private func onAttachmentPresentationChange(_ active: Bool) {
        attachmentPresentationIsActive = active
    }

    private func onLinkOrAlertPresentationChange(_ presented: Bool) {
        if presented {
            terminalLinkOrAlertPaneIDs.insert("%fixture")
        } else {
            terminalLinkOrAlertPaneIDs.remove("%fixture")
        }
    }

    private func finishSharedImport() {}

    private var matchesWindowActionsSource: Bool {
        windowActionsSource != nil
    }

    private func releaseTabPanelViewport() {}
    private func fitTerminalIfReady() {}

    // PRODUCTION_ATTACHMENT_CALLBACKS
    // PRODUCTION_WINDOW_ACTION_DISMISSAL
    // PRODUCTION_TERMINAL_LINK_AND_ALERT_PRESENTATION
}

private enum UIImagePickerController {
    enum Source { case camera }
    static func isSourceTypeAvailable(_: Source) -> Bool {
        true
    }
}

private struct ImageUploadSource {
    let displayName: String
    let data: Data
}

struct ProbeView: View {
    let presentation: Presentation
    let activeService: Service?
    @State private var isKeyboardActive = false
    private var isViewVisible: Bool {
        presentation.pageVisible
    }

    private var terminalIsVisible: Bool {
        presentation.terminalVisible
    }

    private var visibleTerminalWindow: Int? {
        terminalIsVisible ? 1 : nil
    }

    private var activePaneId: String? {
        activeService?.paneId
    }

    private var showsTabPanel: Bool {
        presentation.windowActionsSource != nil
    }

    private var renamingWindow: String? {
        presentation.renamingWindow
    }

    private var closeConfirmation: String? {
        presentation.closeConfirmation
    }

    private var commandError: String? {
        presentation.commandError
    }

    private var hookTrustMessage: String? {
        presentation.hookTrustMessage
    }

    private let copySnapshotPaneID: String? = nil
    private let creationSheetIsPresented = false
    private let sessionInfoSource: Int? = nil

    private var artifactPreviewIsPresented: Bool {
        get { presentation.artifactPreviewIsPresented }
        nonmutating set { presentation.artifactPreviewIsPresented = newValue }
    }

    private var previewFilesLink: String? {
        get { presentation.previewFilesLink }
        nonmutating set { presentation.previewFilesLink = newValue }
    }

    private var pendingFileLink: String? {
        get { presentation.pendingFileLink }
        nonmutating set { presentation.pendingFileLink = newValue }
    }

    private var terminalLinkOrAlertPaneIDs: Set<String> {
        presentation.terminalLinkOrAlertPaneIDs
    }

    private var attachmentPresentationIsActive: Bool {
        presentation.attachmentPresentationIsActive
    }

    private var pendingBrowserLink: String? {
        presentation.pendingBrowserLink
    }

    private var scenePhase: ScenePhase {
        presentation.phase
    }

    private var activeSessionHasBlockingForm: Bool {
        false
    }

    // PRODUCTION_VISIBILITY

    var body: some View {
        Text(terminalIsVisible ? "Terminal" : "Resource")
            // PRODUCTION_STATE_CALLBACK
            // PRODUCTION_VISIBILITY_CALLBACK
            // PRODUCTION_PASTE_ERROR_CALLBACK
            .task {
                presentation.request = { markVisibleTerminalHandled() }
                presentation.dismissPreview = { artifactPreviewDidDismiss() }
                markVisibleTerminalHandled()
            }
    }

    // PRODUCTION_ACKNOWLEDGEMENT
    // PRODUCTION_PREVIEW_DISMISSAL

    private func restorePreviewKeyboard() {}
}

@main struct CompletionAttentionFixture {
    private enum PreviewExit {
        case terminal
        case files
    }

    private enum ChildPanel: CaseIterable {
        case link
        case linkToHostBrowser
        case fileReference
        case uploadPreview
    }

    private enum AttachmentPicker: CaseIterable {
        case photos
        case files
        case camera
    }

    private enum TerminalTransition: CaseIterable {
        case openFiles
        case cancelFiles
        case rename
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                for page in [false, true] {
                    for terminal in [false, true] {
                        for active in [false, true] {
                            try await check(page: page, terminal: terminal, active: active)
                        }
                    }
                }
                try await check(page: true, terminal: true, active: true, previewExit: .terminal)
                try await check(page: true, terminal: true, active: true, previewExit: .files)
                try await checkChildPanels()
                try await checkAttachmentPickers()
                try await checkFilesAndWindowAlerts()
                try await checkChildAlerts()
                print("PASS: visibility, delayed callbacks, previews, child panels, attachment pickers, Files, alerts, child errors and read-on-return")
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func checkChildAlerts() async throws {
        let presentation = Presentation()
        let service = Service()
        let host = NSHostingView(rootView: ProbeView(presentation: presentation, activeService: service))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await settle(host)

        func checkAlert(_ name: String, transition: () -> Void = {}, dismiss: () -> Void) async throws {
            let count = service.relayClient.commands
            service.sessionStore.value.state = .doneWorking(summary: "Finished behind \(name)")
            try await settle(host)
            transition()
            try await settle(host)
            presentation.request?()
            try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was acknowledged behind \(name)")
            dismiss()
            try await settle(host)
            try require(service.sessionStore.acknowledgements == count + 1 && service.relayClient.commands == count + 1, "Completion was not acknowledged once after dismissing \(name)")
        }

        let operationID = UUID()
        presentation.operationID = operationID
        presentation.setAttachmentSelectionActive(true)
        try await checkAlert("Image Input Failed", transition: {
            presentation.presentSourceError(failure("Unreadable image"), operationID: operationID)
            presentation.finishOperation(operationID)
        }) { presentation.setSourceErrorMessage(nil) }

        presentation.windowActionsSource = "tab"
        presentation.pendingWindowMenuAction = { [weak presentation] in presentation?.setEmptySnapshotAlert(true) }
        try await checkAlert("No Terminal Text", transition: presentation.windowActionsDidDismiss) {
            presentation.setEmptySnapshotAlert(false)
        }

        presentation.setPasteError("Clipboard text exceeds 64 KiB.")
        try await checkAlert("Paste Failed") { presentation.setPasteError(nil) }

        presentation.coordinator.pasteError = "Host could not paste the text."
        try await settle(host)
        try await checkAlert("Paste Failed after a Host error") { presentation.setPasteError(nil) }
    }

    @MainActor private static func checkFilesAndWindowAlerts() async throws {
        let presentation = Presentation()
        let service = Service()
        let host = NSHostingView(rootView: ProbeView(presentation: presentation, activeService: service))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await settle(host)

        for (count, transition) in TerminalTransition.allCases.enumerated() {
            if transition == .rename {
                presentation.windowActionsSource = "tab"
            } else {
                presentation.pendingFileLink = "direct-files"
            }
            service.sessionStore.value.state = .doneWorking(summary: "Finished during \(transition)")
            try await settle(host)
            try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was acknowledged while starting \(transition)")
            if transition == .rename {
                presentation.pendingWindowMenuAction = { [weak presentation] in presentation?.renamingWindow = "tab" }
                presentation.windowActionsDidDismiss()
                try require(presentation.renamingWindow != nil && presentation.windowActionsSource == nil, "More did not hand off to Rename Tab")
                try await settle(host)
                presentation.request?()
                try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was acknowledged during Rename Tab")
                presentation.renamingWindow = nil
            } else {
                if transition == .openFiles {
                    presentation.terminalVisible = false
                }
                presentation.pendingFileLink = nil
                if transition == .openFiles {
                    try await settle(host)
                    try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was acknowledged in Files")
                    presentation.terminalVisible = true
                }
            }
            try await settle(host)
            try require(service.sessionStore.acknowledgements == count + 1 && service.relayClient.commands == count + 1, "Completion was not acknowledged once after \(transition)")
        }

        let alerts: [(String, ReferenceWritableKeyPath<Presentation, String?>)] = [
            ("Close Session", \.closeConfirmation),
            ("Error", \.commandError),
            ("Hook Approval", \.hookTrustMessage),
        ]
        for (name, state) in alerts {
            let count = service.relayClient.commands
            presentation[keyPath: state] = name
            service.sessionStore.value.state = .doneWorking(summary: "Finished behind \(name)")
            try await settle(host)
            presentation.request?()
            try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was acknowledged behind \(name)")
            presentation[keyPath: state] = nil
            try await settle(host)
            try require(service.sessionStore.acknowledgements == count + 1 && service.relayClient.commands == count + 1, "Completion was not acknowledged once after dismissing \(name)")
        }
    }

    @MainActor private static func checkAttachmentPickers() async throws {
        let presentation = Presentation()
        let service = Service()
        let host = NSHostingView(rootView: ProbeView(presentation: presentation, activeService: service))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await settle(host)

        var count = 0
        for picker in AttachmentPicker.allCases {
            for opensPreview in [false, true] {
                switch picker {
                case .photos:
                    presentation.choosePhotos()
                    try require(presentation.isPhotoPickerPresented, "Photos picker did not open")
                case .files:
                    presentation.chooseFiles()
                    try require(presentation.isFileImporterPresented, "File picker did not open")
                case .camera:
                    presentation.takePhoto()
                    try require(presentation.isCameraPresented, "Camera did not open")
                    presentation.pageVisible = false
                }
                service.sessionStore.value.state = .doneWorking(summary: "Finished during attachment selection")
                try await settle(host)
                try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was acknowledged while choosing an attachment")

                // The picker binding can clear before its result or cancellation callback.
                presentation.isPhotoPickerPresented = false
                presentation.isFileImporterPresented = false
                presentation.isCameraPresented = false
                presentation.pageVisible = true
                try await settle(host)
                try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was acknowledged during the picker handoff")
                if picker == .camera {
                    presentation.capturedPhoto = opensPreview ? Data([1]) : nil
                    presentation.cameraDidDismiss()
                    try require(presentation.preparingPhoto == opensPreview, "Camera dismissal did not handle capture and cancellation separately")
                }
                if opensPreview {
                    try await settle(host)
                    try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was acknowledged before attachment preparation finished")
                    presentation.presentPreview()
                    presentation.setAttachmentSelectionActive(false)
                    presentation.isPreviewPresented = false
                    try await settle(host)
                    try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was acknowledged before the upload preview finished dismissing")
                    presentation.previewCoversTerminal = false
                    presentation.publishAttachmentPresentation()
                } else {
                    presentation.setAttachmentSelectionActive(false)
                }
                count += 1
                try await settle(host)
                try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was not acknowledged once after returning from the attachment picker")
            }
        }
    }

    @MainActor private static func checkChildPanels() async throws {
        let presentation = Presentation()
        let service = Service()
        let host = NSHostingView(rootView: ProbeView(presentation: presentation, activeService: service))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await settle(host)

        for (count, panel) in ChildPanel.allCases.enumerated() {
            switch panel {
            case .uploadPreview:
                presentation.attachmentPresentationIsActive = true
            case .fileReference:
                presentation.setFileLinkActions("linked-file")
            case .link, .linkToHostBrowser:
                presentation.terminalLinkOrAlertPaneIDs = [service.paneId]
            }
            try await settle(host)
            service.sessionStore.value.state = .doneWorking(summary: "Finished behind \(panel)")
            try await settle(host)
            presentation.request?()
            try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was acknowledged behind \(panel)")

            if panel == .linkToHostBrowser {
                presentation.pendingBrowserLink = "host-browser"
            }
            switch panel {
            case .uploadPreview:
                presentation.attachmentPresentationIsActive = false
            case .fileReference:
                presentation.setFileLinkActions(nil)
            case .link, .linkToHostBrowser:
                presentation.terminalLinkOrAlertPaneIDs.removeAll()
            }
            if panel == .linkToHostBrowser {
                try await settle(host)
                try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was acknowledged while opening the Host browser")
                presentation.terminalVisible = false
                presentation.pendingBrowserLink = nil
                try await settle(host)
                try require(service.sessionStore.acknowledgements == count && service.relayClient.commands == count, "Completion was acknowledged in the Host browser")
                presentation.terminalVisible = true
            }
            try await settle(host)
            try require(service.sessionStore.acknowledgements == count + 1 && service.relayClient.commands == count + 1, "Completion was not acknowledged once after returning from \(panel)")
        }
    }

    @MainActor private static func check(page: Bool, terminal: Bool, active: Bool, previewExit: PreviewExit? = nil) async throws {
        let presentation = Presentation()
        presentation.pageVisible = page
        presentation.terminalVisible = terminal
        presentation.phase = active ? .active : .background
        let service = Service()
        let host = NSHostingView(rootView: ProbeView(presentation: presentation, activeService: service))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await settle(host)
        if previewExit != nil {
            presentation.artifactPreviewIsPresented = true
            try await settle(host)
        }
        service.sessionStore.value.state = .doneWorking(summary: "Finished")
        try await settle(host)
        let visible = page && terminal && active && previewExit == nil
        try require(service.sessionStore.acknowledgements == (visible ? 1 : 0), "Hidden/inactive completion was acknowledged")
        try require(service.relayClient.commands == (visible ? 1 : 0), "Hidden/inactive acknowledgement reached transport")
        if let previewExit {
            if previewExit == .files {
                presentation.previewFilesLink = "preview-file"
            }
            presentation.request?()
            try require(service.sessionStore.acknowledgements == 0, "A delayed callback acknowledged a completion during preview dismissal")
            try require(presentation.dismissPreview != nil, "Preview dismissal callback did not attach")
            presentation.dismissPreview?()
            if previewExit == .files {
                try await settle(host)
                try require(presentation.pendingFileLink == "preview-file", "Dismissal did not hand the preview off to Files")
                try require(presentation.previewFilesLink == nil, "Preview handoff did not consume the Files request")
                try require(service.sessionStore.acknowledgements == 0 && service.relayClient.commands == 0, "Completion was acknowledged while opening Files from the preview")
                presentation.terminalVisible = false
                presentation.previewFilesLink = nil
                presentation.pendingFileLink = nil
                try await settle(host)
                try require(service.sessionStore.acknowledgements == 0 && service.relayClient.commands == 0, "Completion was acknowledged in Files")
            }
        }
        presentation.pageVisible = true
        presentation.terminalVisible = true
        presentation.phase = .active
        try await settle(host)
        try require(service.sessionStore.value.state == .idle && service.sessionStore.acknowledgements == 1 && service.relayClient.commands == 1, "Read-on-return failed or duplicated")
        for state in [State.working, .idle, .awaitingPermission, .awaitingReplies, .awaitingPlanApproval] {
            service.sessionStore.value.state = state
            presentation.request?()
            try await settle(host)
            try require(service.sessionStore.value.state == state && service.relayClient.commands == 1, "Non-completion was acknowledged")
        }
        service.sessionStore.value.state = .doneWorking(summary: "Viewed now")
        presentation.request?()
        try require(service.sessionStore.value.state == .idle, "Local acknowledgement was deferred")
        presentation.pageVisible = false
        try await settle(host)
        try require(service.relayClient.commands == 2, "Accepted acknowledgement did not finish after leaving")
        presentation.pageVisible = true
        // A delayed view callback must recheck eligibility before acknowledging.
        service.sessionStore.value.state = .doneWorking(summary: "Delayed")
        Task { @MainActor in presentation.request?() }
        presentation.pageVisible = false
        try await settle(host)
        try require(service.relayClient.commands == 2, "Late callback acknowledged a departed page")
        presentation.pageVisible = true
        service.relayClient.workspaceInputState.current.generation += 1
        presentation.request?()
        try await settle(host)
        try require(service.relayClient.commands == 2, "A retired binding acknowledged its replacement")
    }

    @MainActor private static func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
    }
}

private func failure(_ message: String) -> NSError {
    .init(domain: "CompletionAttentionUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw failure(message)
    }
}
