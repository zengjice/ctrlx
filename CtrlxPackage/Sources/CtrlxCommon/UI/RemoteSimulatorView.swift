import CtrlxNetworking
import ImageIO
import SwiftUI

/// Paired clients only observe or annotate screenshots, without taking simulator control.
public struct RemoteSimulatorView: View {
    private let tab: RemoteSimulatorTab
    private let client: ViewerRelayClient
    @State private var session: RemoteSimulatorSession
    @State private var displayed: DisplayedPreview?
    @State private var decodingError: String?
    @State private var annotation: AnnotationRequest?
    @Environment(\.browserAnnotationContext) private var annotationContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale

    private struct DisplayedPreview {
        let response: RemoteSimulatorResponse
        let image: CGImage
    }

    private struct AnnotationRequest {
        let id = UUID()
        let jpeg: Data
        let target: AgentImageTarget?
    }

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
                Button(action: beginAnnotation) {
                    Label("Annotate Screenshot", symbol: .pencilLine).labelStyle(.iconOnly)
                }
                .disabled(displayed == nil || !client.isHostConnected || annotationContext?.isAvailable != true)
                .help("Mark a screenshot and add it to an Agent input")
                .accessibilityIdentifier("simulator-annotate")
            }
            .disabled(annotation != nil)
            .padding(8)
            Divider()
            if let error = client.isHostConnected ? (session.error ?? decodingError) : "Host disconnected" {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(6)
            }
            BrowserAnnotationSurface(
                preferredTarget: annotation?.target,
                requiresRecipientSelection: annotation?.target == nil,
                capture: {
                    guard let annotation else { throw AgentImageError.message("No simulator screenshot selected.") }
                    return annotation.jpeg
                },
                onEditingChanged: { editing in
                    if !editing {
                        annotation = nil
                    }
                },
                captureRequest: annotation?.id,
                showsCaptureButton: false,
                identifierPrefix: "simulator"
            ) {
                GeometryReader { geometry in
                    ZStack {
                        Color.black
                        if let displayed {
                            Image(decorative: displayed.image, scale: 1).resizable().scaledToFit()
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
        .task(id: scenePhase == .active && client.isHostConnected && annotation == nil) {
            guard scenePhase == .active, client.isHostConnected, annotation == nil else { session.stop()
                return
            }
            await session.watch()
        }
        .task(id: session.preview) {
            guard annotation == nil else { return }
            guard let preview = session.preview else { displayed = nil
                decodingError = nil
                return
            }
            let decoded = await Self.decode(preview.frame)
            guard !Task.isCancelled, annotation == nil else { return }
            displayed = decoded.map { DisplayedPreview(response: preview, image: $0) }
            decodingError = decoded == nil ? "Cannot decode simulator preview" : nil
        }
        .onDisappear { session.stop()
            displayed = nil
            annotation = nil
        }
        .accessibilityIdentifier("remote-simulator-content")
    }

    private func beginAnnotation() {
        guard
            annotation == nil, let displayed, scenePhase == .active,
            client.isHostConnected, let context = annotationContext, context.isAvailable else { return }
        do {
            let jpeg = try session.annotationScreenshot(from: displayed.response)
            annotation = AnnotationRequest(
                jpeg: jpeg,
                target: context.targets.first { $0.paneID == displayed.response.tab.sourcePaneID }
            )
            decodingError = nil
        } catch {
            decodingError = error.localizedDescription
        }
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
