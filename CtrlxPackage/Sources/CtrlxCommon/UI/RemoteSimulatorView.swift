import CtrlxNetworking
import ImageIO
import SwiftUI

/// Paired clients only observe or annotate screenshots, without taking simulator control.
public struct RemoteSimulatorView: View {
    private let tab: RemoteSimulatorTab
    private let client: ViewerRelayClient
    @State private var session: RemoteSimulatorSession
    @State private var image: CGImage?
    @State private var decodingError: String?
    @State private var captureRequest: UUID?
    @State private var isAnnotating = false
    @Environment(\.browserAnnotationContext) private var annotationContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale

    public init(tab: RemoteSimulatorTab, client: ViewerRelayClient) {
        self.tab = tab
        self.client = client
        _session = State(initialValue: RemoteSimulatorSession(tab: tab, client: client))
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(tab.title, symbol: .iphone).lineLimit(1)
                Spacer()
                Text("Host · Read only").font(.caption).foregroundStyle(.secondary)
                Button { captureRequest = UUID() } label: {
                    Label("Annotate Screenshot", symbol: .pencilLine).labelStyle(.iconOnly)
                }
                .disabled(image == nil || !client.isHostConnected || annotationContext?.isAvailable != true)
                .help("Mark a screenshot and add it to an Agent input")
                .accessibilityIdentifier("simulator-annotate")
            }
            .disabled(isAnnotating)
            .padding(8)
            Divider()
            if let error = client.isHostConnected ? (session.error ?? decodingError) : "Host disconnected" {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(6)
            }
            BrowserAnnotationSurface(
                preferredTarget: preferredTarget,
                requiresRecipientSelection: preferredTarget == nil,
                capture: { try await session.annotationScreenshot() },
                onEditingChanged: { editing in
                    isAnnotating = editing
                    if editing {
                        session.stop()
                    }
                },
                captureRequest: captureRequest,
                showsCaptureButton: false,
                identifierPrefix: "simulator"
            ) {
                GeometryReader { geometry in
                    ZStack {
                        Color.black
                        if let image {
                            Image(decorative: image, scale: 1).resizable().scaledToFit()
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                    .onChange(of: geometry.size, initial: true) { _, size in
                        updateDimension(size)
                    }
                    .onChange(of: displayScale) { _, _ in updateDimension(geometry.size) }
                    .onChange(of: session.frame.map { CGSize(width: $0.width, height: $0.height) }) { _, _ in
                        updateDimension(geometry.size)
                    }
                }
            }
        }
        .task(id: scenePhase == .active && client.isHostConnected && !isAnnotating) {
            guard scenePhase == .active, client.isHostConnected, !isAnnotating else { session.stop()
                return
            }
            await session.watch()
        }
        .task(id: session.frame) {
            guard let frame = session.frame else { image = nil
                decodingError = nil
                return
            }
            let decoded = await Self.decode(frame)
            guard !Task.isCancelled else { return }
            image = decoded
            decodingError = decoded == nil ? "Cannot decode simulator preview" : nil
        }
        .onDisappear { session.stop() }
        .accessibilityIdentifier("remote-simulator-content")
    }

    private var preferredTarget: AgentImageTarget? {
        annotationContext?.targets.first { $0.paneID == tab.sourcePaneID }
    }

    private func updateDimension(_ size: CGSize) {
        guard let frame = session.frame else { return }
        if
            let dimension = RemoteBrowserGeometry.frameMaxDimension(
                viewSize: size,
                pageSize: CGSize(width: frame.width, height: frame.height),
                displayScale: displayScale
            ) {
            session.frameMaxDimension = dimension
        }
    }

    @concurrent
    static func decode(_ frame: RemoteSimulatorFrame) async -> CGImage? {
        guard
            frame.isValid, let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            properties[kCGImagePropertyPixelWidth] as? Int == frame.width,
            properties[kCGImagePropertyPixelHeight] as? Int == frame.height else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
