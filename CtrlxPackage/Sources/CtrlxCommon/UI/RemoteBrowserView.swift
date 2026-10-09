#if os(macOS) || os(iOS)
import CtrlxNetworking
import Dependencies
import ImageIO
import SwiftUI

@MainActor
public struct RemoteBrowserView: View {
    @State private var session: RemoteBrowserSession
    @State private var address = ""
    @State private var image: CGImage?
    @State private var displayedFrame: RemoteBrowserFrame?
    @State private var viewport = CGSize.zero
    @State private var keyboardRequested = false
    @FocusState private var editingAddress: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Dependency(ClipboardClient.self) private var clipboard
    private let client: ViewerRelayClient

    public init(tab: RemoteBrowserTab, client: ViewerRelayClient) {
        self.client = client
        _session = State(initialValue: RemoteBrowserSession(tab: tab, client: client))
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { session.submit(.back) } label: { Label("Back", symbol: .chevronLeft) }
                Button { session.submit(.forward) } label: { Label("Forward", symbol: .chevronRight) }
                Button { session.submit(.reload) } label: { Label("Reload", symbol: .arrowClockwise) }
                TextField("https://…", text: $address)
                    .focused($editingAddress)
                    .onSubmit(navigate)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                Button {
                    session.submit(.fit(width: Int(max(240, min(viewport.width, 2560))),
                                        height: Int(max(240, min(viewport.height, 2560)))))
                } label: { Label("Fit to This Device", symbol: .arrowUpLeftAndArrowDownRight) }
                .help("Changes the page viewport on the Host and all Viewers")
            }
            .labelStyle(.iconOnly)
            .disabled(session.controlID == nil)
            .padding(8)
            HStack {
                Label("Host · Chromium", symbol: .globe).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if session.controlID != nil {
                    Button {
                        if let text = clipboard.getString(), !text.isEmpty { session.submit(.text(text)) }
                    } label: { Label("Paste", symbol: .docOnClipboard).labelStyle(.iconOnly) }
                    #if os(iOS)
                    Button { keyboardRequested.toggle() } label: {
                        Label("Keyboard", symbol: .keyboard).labelStyle(.iconOnly)
                    }
                    #endif
                    Button(session.tab.isAgentOwned ? "Return to Agent" : "Release Control") {
                        keyboardRequested = false
                        session.releaseControl()
                    }
                } else {
                    Button(session.tab.isControlled ? "Read Only · Take Control" : "Take Control") {
                        Task { await session.takeControl() }
                    }
                    .disabled(session.isTakingControl || !client.isHostConnected || session.frame == nil)
                }
            }.padding(.horizontal, 8).padding(.bottom, 8)
            Divider()
            RemoteBrowserCanvas(image: image, frame: displayedFrame,
                                acceptsInput: session.controlID != nil && !editingAddress,
                                keyboardRequested: keyboardRequested) { operation in
                if let displayedFrame { session.submit(operation, generation: displayedFrame.generation) }
            }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
                .overlay {
                    if image == nil {
                        if client.isHostConnected { ProgressView("Connecting to Host page…") }
                        else { Text("Host disconnected").padding() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = session.error ?? session.frameError {
                HStack {
                    Text(error).font(.caption)
                    Spacer()
                    Button { session.dismissError() } label: { Label("Dismiss", symbol: .xmark) }.labelStyle(.iconOnly)
                }.padding(8)
            }
        }
        .task(id: scenePhase == .active && client.isHostConnected && client.hostSupportsBrowserSharing) {
            guard scenePhase == .active, client.isHostConnected, client.hostSupportsBrowserSharing else {
                session.stop(); image = nil; displayedFrame = nil; return
            }
            await session.watch()
        }
        .task(id: session.frame) {
            guard let frame = session.frame else { image = nil; displayedFrame = nil; return }
            let decoded = await BrowserFrameDecoder.decode(frame.jpeg)
            if !Task.isCancelled { image = decoded; displayedFrame = decoded == nil ? nil : frame }
        }
        .onChange(of: session.tab.url, initial: true) { _, url in
            if !editingAddress { address = url == "about:blank" ? "" : url }
        }
        .onDisappear { session.stop() }
        .accessibilityIdentifier("remote-browser-page")
    }

    private func navigate() {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://"), value != "about:blank" { value = "https://" + value }
        session.submit(.navigate(value))
        editingAddress = false
    }
}

private enum BrowserFrameDecoder {
    @concurrent static func decode(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

public enum RemoteBrowserGeometry {
    public static func imageRect(viewSize: CGSize, pageSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0, pageSize.width > 0, pageSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / pageSize.width, viewSize.height / pageSize.height)
        let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    public static func pagePoint(_ point: CGPoint, viewSize: CGSize, pageSize: CGSize, clamped: Bool = false) -> CGPoint? {
        let rect = imageRect(viewSize: viewSize, pageSize: pageSize)
        guard rect.width > 0, clamped || rect.contains(point) else { return nil }
        return CGPoint(x: max(0, min(pageSize.width - 1, (point.x - rect.minX) * pageSize.width / rect.width)),
                       y: max(0, min(pageSize.height - 1, (point.y - rect.minY) * pageSize.height / rect.height)))
    }
}

#if os(macOS)
import AppKit

private struct RemoteBrowserCanvas: NSViewRepresentable {
    let image: CGImage?
    let frame: RemoteBrowserFrame?
    let acceptsInput: Bool
    let keyboardRequested: Bool
    let send: (RemoteBrowserOperation) -> Void
    func makeNSView(context: Context) -> BrowserCanvasNSView { BrowserCanvasNSView() }
    func updateNSView(_ view: BrowserCanvasNSView, context: Context) {
        view.image = image
        view.pageSize = frame.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        view.acceptsInput = acceptsInput
        view.send = send
        view.needsDisplay = true
    }
}

final class BrowserCanvasNSView: NSView, @preconcurrency NSTextInputClient {
    @Dependency(ClipboardClient.self) private var clipboard
    var image: CGImage?
    var pageSize = CGSize.zero
    var acceptsInput = false
    var send: (RemoteBrowserOperation) -> Void = { _ in }
    private var marked = NSAttributedString(string: "")
    private var pointerTrackingArea: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { acceptsInput }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let image else { return }
        let target = RemoteBrowserGeometry.imageRect(viewSize: bounds.size, pageSize: pageSize)
        NSImage(cgImage: image, size: target.size).draw(in: target, from: .zero, operation: .copy, fraction: 1,
                                                     respectFlipped: true, hints: nil)
    }
    private func modifiers(_ event: NSEvent) -> Int {
        (event.modifierFlags.contains(.option) ? 1 : 0) | (event.modifierFlags.contains(.control) ? 2 : 0)
            | (event.modifierFlags.contains(.command) ? 4 : 0) | (event.modifierFlags.contains(.shift) ? 8 : 0)
    }
    private func pointer(_ event: NSEvent, kind: RemoteBrowserPointer.Kind, button: RemoteBrowserPointer.Button = .none, buttons: Int = 0) {
        guard acceptsInput, let point = RemoteBrowserGeometry.pagePoint(convert(event.locationInWindow, from: nil),
            viewSize: bounds.size, pageSize: pageSize, clamped: kind == .up || (kind == .move && buttons != 0)) else { return }
        let clickCount = kind == .down || kind == .up ? min(3, event.clickCount) : 0
        send(.pointer(.init(kind, x: point.x, y: point.y, button: button, buttons: buttons,
                            modifiers: modifiers(event), clickCount: clickCount,
                            deltaX: kind == .scroll ? max(-4096, min(4096, -event.scrollingDeltaX)) : 0,
                            deltaY: kind == .scroll ? max(-4096, min(4096, -event.scrollingDeltaY)) : 0)))
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, kind: .down, button: .left, buttons: 1) }
    override func mouseUp(with event: NSEvent) { pointer(event, kind: .up, button: .left) }
    override func mouseMoved(with event: NSEvent) { pointer(event, kind: .move) }
    override func mouseDragged(with event: NSEvent) { pointer(event, kind: .move, button: .left, buttons: 1) }
    override func rightMouseDown(with event: NSEvent) { pointer(event, kind: .down, button: .right, buttons: 2) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, kind: .up, button: .right) }
    override func scrollWheel(with event: NSEvent) { pointer(event, kind: .scroll) }
    override func keyDown(with event: NSEvent) {
        guard acceptsInput else { return }
        let keys: [UInt16: (String, Int)] = [
            123: ("ArrowLeft", 37), 124: ("ArrowRight", 39), 125: ("ArrowDown", 40), 126: ("ArrowUp", 38),
            115: ("Home", 36), 119: ("End", 35), 116: ("PageUp", 33), 121: ("PageDown", 34),
            48: ("Tab", 9), 53: ("Escape", 27), 117: ("Delete", 46),
        ]
        if marked.length == 0, let key = keys[event.keyCode] {
            send(.key(.init(key.0, keyCode: key.1, modifiers: modifiers(event))))
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" {
            if let value = clipboard.getString() { send(.text(value)) }
        } else if event.modifierFlags.intersection([.command, .control]).isEmpty {
            interpretKeyEvents([event])
        } else if let value = event.charactersIgnoringModifiers, let code = value.uppercased().utf16.first {
            send(.key(.init(value, keyCode: Int(code), modifiers: modifiers(event))))
        }
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard acceptsInput else { return }
        let value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = NSAttributedString(string: "")
        if !value.isEmpty { send(.text(value)) }
    }
    override func doCommand(by selector: Selector) {
        let keys: [String: (String, Int)] = ["insertNewline:": ("Enter", 13), "deleteBackward:": ("Backspace", 8),
            "deleteForward:": ("Delete", 46), "insertTab:": ("Tab", 9), "cancelOperation:": ("Escape", 27),
            "moveLeft:": ("ArrowLeft", 37), "moveRight:": ("ArrowRight", 39),
            "moveUp:": ("ArrowUp", 38), "moveDown:": ("ArrowDown", 40),
            "moveToBeginningOfLine:": ("Home", 36), "moveToEndOfLine:": ("End", 35)]
        if acceptsInput, let key = keys[NSStringFromSelector(selector)] { send(.key(.init(key.0, keyCode: key.1))) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
    }
    func unmarkText() { marked = NSAttributedString(string: "") }
    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func markedRange() -> NSRange { NSRange(location: marked.length == 0 ? NSNotFound : 0, length: marked.length) }
    func hasMarkedText() -> Bool { marked.length != 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(NSRect(x: 0, y: bounds.height - 24, width: 1, height: 24), to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}
#elseif os(iOS)
import UIKit

private struct RemoteBrowserCanvas: UIViewRepresentable {
    let image: CGImage?
    let frame: RemoteBrowserFrame?
    let acceptsInput: Bool
    let keyboardRequested: Bool
    let send: (RemoteBrowserOperation) -> Void
    func makeUIView(context: Context) -> BrowserCanvasUIView { BrowserCanvasUIView() }
    func updateUIView(_ view: BrowserCanvasUIView, context: Context) {
        view.picture.image = image.map { UIImage(cgImage: $0) }
        view.pageSize = frame.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        view.acceptsInput = acceptsInput
        view.send = send
        view.keyboard.send = send
        if keyboardRequested && acceptsInput {
            if !view.keyboard.isFirstResponder { view.keyboard.becomeFirstResponder() }
        } else if view.keyboard.isFirstResponder { view.keyboard.resignFirstResponder() }
    }
    static func dismantleUIView(_ view: BrowserCanvasUIView, coordinator: ()) { view.keyboard.resignFirstResponder() }
}

private final class BrowserCanvasUIView: UIView {
    let picture = UIImageView()
    let keyboard = BrowserKeyboardInput()
    var pageSize = CGSize.zero
    var acceptsInput = false
    var send: (RemoteBrowserOperation) -> Void = { _ in }
    private var previous = CGPoint.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        picture.contentMode = .scaleAspectFit
        picture.isUserInteractionEnabled = false
        addSubview(picture)
        keyboard.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        keyboard.alpha = 0.01
        addSubview(keyboard)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        // One finger scrolls; two fingers drag a page element/selection.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(tap); addGestureRecognizer(pan); addGestureRecognizer(drag)
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() { super.layoutSubviews(); picture.frame = bounds }
    private func point(_ gesture: UIGestureRecognizer, clamped: Bool = false) -> CGPoint? {
        guard acceptsInput else { return nil }
        return RemoteBrowserGeometry.pagePoint(gesture.location(in: self), viewSize: bounds.size, pageSize: pageSize, clamped: clamped)
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let point = point(gesture) else { return }
        send(.pointer(.init(.down, x: point.x, y: point.y, button: .left, buttons: 1)))
        send(.pointer(.init(.up, x: point.x, y: point.y, button: .left)))
    }
    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        defer { previous = translation }
        guard gesture.state == .changed, let point = point(gesture) else { return }
        let rect = RemoteBrowserGeometry.imageRect(viewSize: bounds.size, pageSize: pageSize)
        let scale = pageSize.width / max(1, rect.width)
        send(.pointer(.init(.scroll, x: point.x, y: point.y,
                            deltaX: max(-4096, min(4096, (previous.x - translation.x) * scale)),
                            deltaY: max(-4096, min(4096, (previous.y - translation.y) * scale)))))
    }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let point = point(gesture, clamped: gesture.state != .began) else { return }
        let kind: RemoteBrowserPointer.Kind = gesture.state == .began ? .down : gesture.state == .changed ? .move : .up
        send(.pointer(.init(kind, x: point.x, y: point.y, button: .left, buttons: kind == .up ? 0 : 1)))
    }
}

/// UIKit owns composition/candidate UI. Only committed text crosses the wire.
private final class BrowserKeyboardInput: UITextView, UITextViewDelegate {
    var send: (RemoteBrowserOperation) -> Void = { _ in }
    private let sentinel = "\u{200B}"
    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        reset()
    }
    required init?(coder: NSCoder) { nil }
    private func reset() { text = sentinel; selectedRange = NSRange(location: 1, length: 0) }
    func textViewDidChange(_ textView: UITextView) {
        guard markedTextRange == nil else { return }
        let value = text.hasPrefix(sentinel) ? String(text.dropFirst()) : text ?? ""
        if !value.isEmpty { send(.text(value)) }
        reset()
    }
    override func deleteBackward() {
        if markedTextRange == nil, text == sentinel { send(.key(.init("Backspace", keyCode: 8))) }
        else { super.deleteBackward() }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard markedTextRange == nil else { super.pressesBegan(presses, with: event); return }
        let keys: [UIKeyboardHIDUsage: (String, Int)] = [
            .keyboardLeftArrow: ("ArrowLeft", 37), .keyboardRightArrow: ("ArrowRight", 39),
            .keyboardUpArrow: ("ArrowUp", 38), .keyboardDownArrow: ("ArrowDown", 40),
            .keyboardHome: ("Home", 36), .keyboardEnd: ("End", 35),
            .keyboardPageUp: ("PageUp", 33), .keyboardPageDown: ("PageDown", 34),
            .keyboardTab: ("Tab", 9), .keyboardEscape: ("Escape", 27),
        ]
        var remaining = presses
        for press in presses {
            guard let key = press.key else { continue }
            let flags = key.modifierFlags
            let modifiers = (flags.contains(.alternate) ? 1 : 0) | (flags.contains(.control) ? 2 : 0)
                | (flags.contains(.command) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0)
            var value = keys[key.keyCode]
            if value == nil, !flags.intersection([.command, .control]).isEmpty,
               key.charactersIgnoringModifiers.lowercased() != "v",
               let code = key.charactersIgnoringModifiers.uppercased().utf16.first, code < 128 {
                value = (key.charactersIgnoringModifiers, Int(code))
            }
            guard let value else { continue }
            send(.key(.init(value.0, keyCode: value.1, modifiers: modifiers)))
            remaining.remove(press)
        }
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n", markedTextRange == nil { send(.key(.init("Enter", keyCode: 13))); return false }
        return true
    }
}
#endif
#endif
