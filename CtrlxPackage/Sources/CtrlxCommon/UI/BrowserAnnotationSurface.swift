#if os(macOS) || os(iOS)
import CtrlxNetworking
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public struct BrowserAnnotationContext {
    public var targets: [AgentImageTarget]
    public var isAvailable: Bool
    public var send: (ClipboardImage, AgentImageTarget) async throws -> Void
    public var didSend: (AgentImageTarget) -> Void

    public init(targets: [AgentImageTarget], isAvailable: Bool = true,
                send: @escaping (ClipboardImage, AgentImageTarget) async throws -> Void,
                didSend: @escaping (AgentImageTarget) -> Void) {
        self.targets = targets; self.isAvailable = isAvailable
        self.send = send; self.didSend = didSend
    }

    public static func remote(targets: [AgentImageTarget], client: ViewerRelayClient,
                              didSend: @escaping (AgentImageTarget) -> Void) -> Self {
        Self(targets: targets, isAvailable: client.isHostConnected && client.hostSupportsAgentImageInput) { image, target in
            let result = try await client.sendCommand(
                SendDroppedFiles(files: [.init(name: "browser-annotation.\(image.format.fileExtension)", data: image.data)], expectedAgent: target),
                paneId: target.paneID, timeout: 30).get()
            guard result.success else { throw AgentImageError.message(result.error ?? "Could not add the screenshot.") }
        } didSend: { didSend($0) }
    }
}

extension EnvironmentValues {
    @Entry public var browserAnnotationContext: BrowserAnnotationContext?
}

public enum BrowserAnnotationTool: String, CaseIterable, Sendable {
    case rectangle = "Rectangle", arrow = "Arrow", pen = "Pen"

    var symbol: Symbols {
        switch self {
        case .rectangle: .annotationRectangle
        case .arrow: .annotationArrow
        case .pen: .pencil
        }
    }
}

/// Unit-image coordinates keep annotations aligned across Retina scale and resizing.
public struct BrowserAnnotationMark: Sendable {
    public var tool: BrowserAnnotationTool
    public var points: [CGPoint]

    public static func point(_ location: CGPoint, viewSize: CGSize, imageSize: CGSize, clamp: Bool = false) -> CGPoint? {
        let rect = RemoteBrowserGeometry.imageRect(viewSize: viewSize, pageSize: imageSize)
        guard rect.width > 0, rect.height > 0, location.x.isFinite, location.y.isFinite,
              clamp || rect.contains(location) else { return nil }
        return CGPoint(x: max(0, min(1, (location.x - rect.minX) / rect.width)),
                       y: max(0, min(1, (location.y - rect.minY) / rect.height)))
    }

    func path(size: CGSize) -> CGPath {
        let path = CGMutablePath()
        let points = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = points.first, let last = points.last else { return path }
        switch tool {
        case .rectangle:
            path.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                width: abs(first.x - last.x), height: abs(first.y - last.y)))
        case .pen:
            path.addLines(between: points)
        case .arrow:
            path.move(to: first); path.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = min(max(10, size.width * 0.018), hypot(last.x - first.x, last.y - first.y) * 0.4)
            for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: last)
                path.addLine(to: CGPoint(x: last.x - head * cos(angle + offset), y: last.y - head * sin(angle + offset)))
            }
        }
        return path
    }
}

enum BrowserAnnotationRenderer {
    @concurrent static func decode(_ data: Data) async throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(RemoteBrowserFrame.maximumDimension, max(width, height)),
              ] as CFDictionary) else {
            throw AgentImageError.message("The page could not be captured as an image.")
        }
        return image
    }

    @concurrent static func prepare(image: CGImage, marks: [BrowserAnnotationMark]) async throws -> ClipboardImage {
        let size = CGSize(width: image.width, height: image.height)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AgentImageError.message("Could not prepare the screenshot.")
        }
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.12, alpha: 1))
        context.setLineWidth(max(2, size.width * 0.003))
        context.setLineCap(.round); context.setLineJoin(.round)
        for mark in marks { context.addPath(mark.path(size: size)); context.strokePath() }
        let bytes = NSMutableData()
        guard let rendered = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw AgentImageError.message("Could not encode the screenshot.")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination),
              let prepared = RelayImagePreparer.prepare(bytes as Data, maxBytes: SendDroppedFiles.maxRawBytes) else {
            throw AgentImageError.message("The screenshot is too large to send. Try a smaller browser viewport.")
        }
        return prepared
    }
}

/// Keeps the native page mounted and the layout unchanged. No sheet, navigation,
/// DOM injection, browser resize or control takeover is needed for annotation.
@MainActor
public struct BrowserAnnotationSurface<Content: View>: View {
    @Environment(\.browserAnnotationContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    let preferredTarget: AgentImageTarget?
    let requiresRecipientSelection: Bool
    let capture: @MainActor () async throws -> Data
    let onEditingChanged: (Bool) -> Void
    let content: Content
    @State private var image: CGImage?
    @State private var marks: [BrowserAnnotationMark] = []
    @State private var stroke: BrowserAnnotationMark?
    @State private var tool: BrowserAnnotationTool = .rectangle
    @State private var target: AgentImageTarget?
    @State private var operation: Operation?
    @State private var error: String?
    private struct Operation: Equatable {
        enum Kind: Equatable { case capture, send }
        let id = UUID()
        let kind: Kind
    }

    public init(preferredTarget: AgentImageTarget? = nil,
                requiresRecipientSelection: Bool = false,
                capture: @escaping @MainActor () async throws -> Data,
                onEditingChanged: @escaping (Bool) -> Void = { _ in },
                @ViewBuilder content: () -> Content) {
        self.preferredTarget = preferredTarget; self.capture = capture
        self.requiresRecipientSelection = requiresRecipientSelection
        self.onEditingChanged = onEditingChanged; self.content = content()
    }

    public var body: some View {
        content
            .allowsHitTesting(image == nil && operation == nil)
            .overlay {
                if let image { canvas(image).disabled(operation != nil) }
                if operation != nil { ProgressView().padding().background(.regularMaterial, in: Capsule()) }
            }
            .overlay(alignment: .topTrailing) {
                if let context {
                    VStack(alignment: .trailing, spacing: 6) {
                        if image != nil {
                            tools(context).disabled(operation != nil)
                        } else {
                            Button {
                                target = requiresRecipientSelection ? nil : AgentImageTarget.defaultTarget(in: context.targets, preferred: preferredTarget)
                                tool = .rectangle; error = nil; operation = Operation(kind: .capture)
                            } label: { Label("Annotate Screenshot", symbol: .pencilLine) }
                            .disabled(!context.isAvailable || operation != nil)
                            .help(context.isAvailable ? "Mark this page and add it to an Agent input" : "Connect and update the Host to add screenshots")
                            .accessibilityIdentifier("browser-annotate")
                        }
                        if let error {
                            Text(error).font(.caption).frame(maxWidth: 320).padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .buttonStyle(.bordered)
                    .padding(8)
                }
            }
            .task(id: operation) {
                guard let operation else { return }
                defer { if self.operation == operation { self.operation = nil } }
                do {
                    switch operation.kind {
                    case .capture:
                        let decoded = try await BrowserAnnotationRenderer.decode(capture())
                        try Task.checkCancellation()
                        image = decoded
                    case .send:
                        guard let context, context.isAvailable, let target, let image,
                              context.targets.contains(where: { $0.paneID == target.paneID && $0.sessionID == target.sessionID && $0.pluginID == target.pluginID }) else {
                            throw AgentImageError.message("The recipient is unavailable. Connect to the Host and choose an Agent.")
                        }
                        let prepared = try await BrowserAnnotationRenderer.prepare(image: image, marks: marks)
                        try Task.checkCancellation()
                        try await context.send(prepared, target)
                        try Task.checkCancellation()
                        reset()
                        context.didSend(target)
                    }
                } catch is CancellationError {
                    // Leaving the browser cancels work, never delivers to a new target.
                } catch { self.error = error.localizedDescription }
            }
            .onChange(of: image != nil || operation != nil) { _, editing in onEditingChanged(editing) }
            .onChange(of: scenePhase) { _, phase in if phase != .active { operation = nil } }
            .onDisappear { operation = nil; onEditingChanged(false) }
    }

    private func tools(_ context: BrowserAnnotationContext) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(BrowserAnnotationTool.allCases, id: \.self) { value in
                    Button { tool = value } label: { Label(value.rawValue, symbol: value.symbol).labelStyle(.iconOnly) }
                        .tint(tool == value ? .red : .primary)
                        .accessibilityIdentifier("browser-annotation-\(value.rawValue.lowercased())")
                }
                Button { _ = marks.popLast() } label: { Label("Undo", symbol: .annotationUndo).labelStyle(.iconOnly) }
                    .disabled(marks.isEmpty)
                Button { marks.removeAll() } label: { Label("Clear", symbol: .trash).labelStyle(.iconOnly) }
                    .disabled(marks.isEmpty)
                Button("Cancel") { reset() }
            }
            HStack(spacing: 4) {
                Menu {
                    ForEach(context.targets) { candidate in
                        Button(candidate.label) { target = candidate; error = nil }
                    }
                    if context.targets.isEmpty { Text("No recognized Codex or Claude Code in this session") }
                } label: { Text(target?.label ?? "Choose Agent").lineLimit(1).frame(maxWidth: 210) }
                Button("Add to Input") { error = nil; operation = Operation(kind: .send) }
                    .disabled(target == nil || !context.isAvailable)
                    .accessibilityIdentifier("browser-annotation-send")
            }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func canvas(_ image: CGImage) -> some View {
        GeometryReader { geometry in
            let size = CGSize(width: image.width, height: image.height)
            let rect = RemoteBrowserGeometry.imageRect(viewSize: geometry.size, pageSize: size)
            Canvas { drawing, _ in
                drawing.draw(Image(decorative: image, scale: 1), in: rect)
                var layer = drawing
                layer.translateBy(x: rect.minX, y: rect.minY)
                for mark in marks + (stroke.map { [$0] } ?? []) {
                    layer.stroke(Path(mark.path(size: rect.size)), with: .color(Color(red: 1, green: 0.15, blue: 0.12)),
                                 style: StrokeStyle(lineWidth: max(2, size.width * 0.003) * rect.width / size.width, lineCap: .round, lineJoin: .round))
                }
            }
            .background(Color.black)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard marks.count < 200,
                          let start = BrowserAnnotationMark.point(value.startLocation, viewSize: geometry.size, imageSize: size),
                          let end = BrowserAnnotationMark.point(value.location, viewSize: geometry.size, imageSize: size, clamp: true) else { return }
                    if stroke == nil { stroke = BrowserAnnotationMark(tool: tool, points: [start]) }
                    if tool == .pen {
                        if (stroke?.points.count ?? 0) < 4000 { stroke?.points.append(end) }
                    } else { stroke?.points = [start, end] }
                }
                .onEnded { _ in
                    if let stroke, stroke.points.count > 1 { marks.append(stroke) }
                    stroke = nil
                })
        }
        .accessibilityLabel("Frozen browser screenshot. Draw to annotate; the live page continues in the background.")
        .accessibilityIdentifier("browser-annotation-canvas")
    }

    private func reset() { image = nil; marks = []; stroke = nil; error = nil }
}
#endif
