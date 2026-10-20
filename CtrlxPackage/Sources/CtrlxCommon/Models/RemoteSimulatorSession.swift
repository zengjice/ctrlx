import CtrlxNetworking
import Dependencies
import Foundation
import Observation

@MainActor @Observable
final public class RemoteSimulatorSession {
    public private(set) var preview: RemoteSimulatorResponse?
    public var frame: RemoteSimulatorFrame? {
        preview?.frame
    }

    public var error: String? {
        inputError ?? previewError
    }

    private var inputError: String?
    private var previewError: String?
    public var frameMaxDimension = 1_024
    public private(set) var controlID: UUID?
    public private(set) var isTakingControl = false
    public private(set) var clipboardMessage: String?
    public var supportsClipboard = false
    @ObservationIgnored @Dependency(ClipboardClient.self) private var clipboard
    @ObservationIgnored private let surfaceID = UUID()
    @ObservationIgnored private var generation: Int?
    @ObservationIgnored private var inputEpoch = UUID()
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var inputs: [(RemoteSimulatorControlOperation, Int?)] = []
    @ObservationIgnored private var control: (@MainActor (ControlSimulator) async throws -> RemoteSimulatorControlResponse)?
    @ObservationIgnored private var tab: RemoteSimulatorTab
    @ObservationIgnored private let send: @MainActor (BrowseSimulator) async throws -> RemoteSimulatorResponse
    @ObservationIgnored private var epoch = UUID()

    public init(tab: RemoteSimulatorTab, control: (@MainActor (ControlSimulator) async throws -> RemoteSimulatorControlResponse)? = nil, send: @escaping @MainActor (BrowseSimulator) async throws -> RemoteSimulatorResponse) {
        self.tab = tab
        self.send = send
        self.control = control
        self.supportsClipboard = control != nil
    }

    public convenience init(tab: RemoteSimulatorTab, client: ViewerRelayClient) {
        self.init(tab: tab, send: { request in
            let result = try await client.sendCommand(request, paneId: "", timeout: 8).get()
            guard result.success, let response = result.simulator else {
                throw ViewerRelayClientError.commandFailed(result.error ?? "Missing simulator response")
            }
            return response
        })
        self.supportsClipboard = client.hostSupportsWorkspaceClipboard
        self.control = { request in
            let result = try await client.sendCommand(request, paneId: "", timeout: 15).get()
            guard result.success, let response = result.simulatorControl else {
                throw ViewerRelayClientError.commandFailed(result.error ?? "Missing simulator control response")
            }
            return response
        }
    }

    public static func open(
        sessionName: String,
        sourcePaneID: String,
        client: ViewerRelayClient,
        inputBinding: ViewerWorkspaceInputBinding,
    ) async throws -> RemoteSimulatorTab {
        let result = try await client.sendCommand(
            OpenPaneSimulator(sessionName: sessionName, sourcePaneID: sourcePaneID),
            paneId: sourcePaneID, timeout: 240, inputBinding: inputBinding,
        ).get()
        try Task.checkCancellation()
        _ = try inputBinding.expectedPane(current: client.workspaceInputState.binding(paneID: sourcePaneID))
        guard result.success, let tab = result.simulatorTab, tab.sessionName == sessionName, tab.sourcePaneID == sourcePaneID else {
            throw ViewerRelayClientError.commandFailed(result.error ?? "Host did not return the source pane's simulator")
        }
        client.rememberOpenedSimulator(tab)
        return tab
    }

    public func watch() async {
        stop()
        let current = epoch
        defer {
            if epoch == current {
                stop()
            }
        }
        while !Task.isCancelled, epoch == current {
            do {
                let sentControl = controlID
                let response = try await requestFrame(tab, maxDimension: frameMaxDimension)
                guard epoch == current else { return }
                tab = response.tab
                preview = response
                previewError = nil
                if controlID == sentControl {
                    generation = response.generation
                    if controlID != response.controlID {
                        releaseControl()
                    }
                }
            } catch is CancellationError { return }
            catch {
                guard epoch == current else { return }
                previewError = error.localizedDescription
            }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        }
    }

    public func stop() {
        epoch = UUID()
        releaseControl()
        preview = nil
    }

    private func request(_ operation: RemoteSimulatorControlOperation, generation: Int? = nil) -> ControlSimulator {
        ControlSimulator(
            sessionName: tab.sessionName,
            tabID: tab.id,
            surfaceID: surfaceID,
            controlID: controlID,
            generation: generation ?? self.generation,
            operation: operation,
        )
    }

    public func takeControl() async {
        guard supportsClipboard, let control, preview != nil, controlID == nil, !isTakingControl else { return }
        isTakingControl = true
        let current = inputEpoch
        defer {
            if current == inputEpoch {
                isTakingControl = false
            }
        }
        let sent = request(.takeControl)
        do {
            let result = try await control(sent)
            guard !Task.isCancelled, current == inputEpoch, preview != nil else {
                _ = try? await control(ControlSimulator(
                    sessionName: sent.sessionName,
                    tabID: sent.tabID,
                    surfaceID: sent.surfaceID,
                    controlID: result.controlID,
                    generation: result.generation,
                    operation: .releaseControl,
                ))
                return
            }
            controlID = result.controlID
            generation = result.generation
            inputError = nil
        } catch {
            if current == inputEpoch {
                inputError = error.localizedDescription
            }
        }
    }

    public func releaseControl() {
        let sent = request(.releaseControl)
        inputEpoch = UUID()
        inputTask?.cancel()
        inputTask = nil
        inputs.removeAll()
        isTakingControl = false
        controlID = nil
        clipboardMessage = nil
        if sent.controlID != nil, let control {
            Task { _ = try? await control(sent) }
        }
    }

    public func copy() {
        submit(.copy)
    }

    public func readClipboard() {
        submit(.readClipboard)
    }

    public func paste() {
        guard controlID != nil else { return }
        do { try submit(.paste(clipboard.workspaceContent())) }
        catch { inputError = error.localizedDescription }
    }

    func send(_ operation: RemoteBrowserOperation, displayed: RemoteSimulatorResponse) {
        guard displayed.tab.id == tab.id, displayed.generation == generation else { return }
        switch operation {
        case let .pointer(pointer):
            guard pointer.kind != .scroll, pointer.kind != .move || pointer.buttons == 1, pointer.button != .right, let geometry = displayed.frame.inputGeometry else { return }
            let phase = pointer.kind == .down ? 0 : pointer.kind == .move ? 1 : 2
            submit(.touch(
                phase: phase,
                x: pointer.x / Double(displayed.frame.width),
                y: pointer.y / Double(displayed.frame.height),
                geometry: geometry,
            ))
        case .copy: copy()
        case let .paste(content): submit(.paste(content))
        default: break
        }
    }

    private func submit(_ operation: RemoteSimulatorControlOperation) {
        guard controlID != nil, let control, preview != nil else { return }
        guard inputs.count < 32 else {
            releaseControl()
            inputError = "Simulator input is busy. Take Control again."
            return
        }
        clipboardMessage = nil
        if
            case let .touch(1, x, y, geometry) = operation,
            let last = inputs.last, last.1 == generation, case .touch(1, _, _, geometry) = last.0 {
            inputs[inputs.count - 1] = (.touch(phase: 1, x: x, y: y, geometry: geometry), generation)
        } else {
            inputs.append((operation, generation))
        }
        guard inputTask == nil else { return }
        let current = inputEpoch
        inputTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if inputEpoch == current {
                    inputTask = nil
                }
            }
            while !inputs.isEmpty, inputEpoch == current, !Task.isCancelled {
                let (operation, generation) = inputs.removeFirst()
                let sent = request(operation, generation: generation)
                do {
                    let result = try await control(sent)
                    guard
                        !Task.isCancelled, inputEpoch == current, controlID == sent.controlID,
                        result.controlID == controlID, result.generation == generation else { return }
                    if operation == .copy || operation == .readClipboard {
                        guard let content = result.clipboard else { throw WorkspaceClipboardError.message("No clipboard content returned") }
                        try clipboard.setWorkspaceContent(content)
                        clipboardMessage = "Copied to this device."
                    } else if case .paste = operation {
                        clipboardMessage = "Paste sent."
                    }
                    inputError = nil
                } catch {
                    guard inputEpoch == current else { return }
                    releaseControl()
                    inputError = error.localizedDescription
                    return
                }
            }
        }
    }

    /// Freeze the decoded, displayed frame, not a newer response still waiting to be displayed.
    public func annotationScreenshot(from displayed: RemoteSimulatorResponse) throws -> Data {
        guard
            preview != nil, displayed.frame.isValid,
            displayed.tab.id == tab.id, displayed.tab.sessionName == tab.sessionName,
            displayed.tab.windowID == tab.windowID, displayed.tab.sourcePaneID == tab.sourcePaneID else {
            throw ViewerRelayClientError.commandFailed("The simulator preview changed. Wait for its current frame and try again.")
        }
        stop()
        return displayed.frame.jpeg
    }

    private func requestFrame(_ tab: RemoteSimulatorTab, maxDimension: Int) async throws -> RemoteSimulatorResponse {
        try Task.checkCancellation()
        let response = try await send(BrowseSimulator(
            sessionName: tab.sessionName, tabID: tab.id, frameMaxDimension: maxDimension, surfaceID: surfaceID, controlID: controlID,
        ))
        try Task.checkCancellation()
        guard
            response.tab.id == tab.id, response.tab.sessionName == tab.sessionName,
            response.frame.isValid else {
            throw ViewerRelayClientError.commandFailed("The simulator changed or its preview is invalid. Reopen the tab and try again.")
        }
        return response
    }
}
