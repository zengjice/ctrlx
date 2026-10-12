#if os(macOS)
    import AppKit
    @preconcurrency import CtrlxSimulatorBridge
    import CtrlxSimulatorProtocol
    import IOSurface
    import Metal
    import QuartzCore
    import Synchronization

    enum SimulatorDisplayMode: String, Sendable {
        case synchronized
        case lowLatency = "low-latency"
    }

    final class SimulatorFrameMailbox: Sendable {
        private struct Pending: Sendable {
            var frame: CXSimulatorFrame?
            var scheduled = false
        }

        private let pending = Mutex(Pending())
        private let deliver: @MainActor @Sendable (CXSimulatorFrame) -> Void

        init(deliver: @escaping @MainActor @Sendable (CXSimulatorFrame) -> Void) {
            self.deliver = deliver
        }

        func receive(_ frame: CXSimulatorFrame) {
            let (schedule, superseded) = pending.withLock { state in
                let previous = state.frame
                let schedule = !state.scheduled
                state.frame = frame
                state.scheduled = true
                return (schedule, previous)
            }
            // Release old leases while the UI is busy so the worker can copy a newer frame.
            superseded?.finish()
            if schedule {
                Task(priority: .userInitiated) { @MainActor [self] in
                    let latest = pending.withLock { state in
                        let frame = state.frame
                        state.frame = nil
                        state.scheduled = false
                        return frame
                    }
                    if let latest { deliver(latest) }
                }
            }
        }
    }

    struct SimulatorRenderCounters: Sendable {
        var initialInFlight = 0
        var receivedFrames = 0
        var replacedPendingFrames = 0
        var drawGateBlocked = 0
        var drawableUnavailable = 0
        var submittedDrawables = 0
        var presentedCallbacks = 0
        var discardedDrawables = 0
        var invalidatedDrawables = 0
        var staleCallbacks = 0
        var maximumInFlight = 0
        var layoutCalls = 0
        var contentsSubmissions = 0
    }

    struct SimulatorDisplayCondition: Sendable, Equatable {
        let displayID: UInt32
        let maximumFPS: Int
        let contentsScale: Double
        let drawableSize: CGSize
    }

    struct SimulatorRenderState: Sendable {
        let counters: SimulatorRenderCounters
        let inFlight: Int
        let generation: Int
        let hasPendingFrame: Bool
        let hasCurrentFrame: Bool
        let redrawNeeded: Bool
        let maximumDrawableCount: Int
        let presentsWithTransaction: Bool
        let layerOpaque: Bool
        let drawableSize: CGSize
        let contentsScale: Double
        let firstInvalidGeometry: SimulatorGeometry?
        let lifecycle: SimulatorRenderLifecycle.Sample?
        let renderer: String
        let steadyPresentationObservable: Bool
        let contentsVisible: Bool
    }

    @MainActor
    final class SimulatorMetalView: NSView {
        var onTouch: (SimulatorPoint, Int) -> Void = { _, _ in }
        var onKey: (Int, Bool) -> Void = { _, _ in }
        var onCancelInput: () -> Void = {}
        var onVisibility: (Bool) -> Void = { _ in }
        var onFirstFrame: () -> Void = {}
        var onError: (String) -> Void = { _ in }
        private(set) var geometry: SimulatorGeometry?
        private let metal: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let metalLayer: CAMetalLayer
        private let imageLayer = CALayer()
        private var displayMode = SimulatorDisplayMode.synchronized
        private let immutableContentsEnabled = CommandLine.arguments.contains("--e2e-simulator-core-animation")
        private var pending: FrameLease?
        private var current: FrameLease?
        private var textures: [UInt32: MTLTexture] = [:]
        private let geometryDecoder = JSONDecoder()
        private var firstInvalidGeometry: SimulatorGeometry?
        private var viewport = CGRect.zero
        private var visible = false
        private var isClosed = false
        private var receivedFrame = false
        private(set) var inputReadyAt = 0.0
        private(set) var inputEventReceivedAt = 0.0
        private(set) var visibilityChangedAt = 0.0
        var inputReady: Bool { visible && receivedFrame }
        private var redrawNeeded = true
        private var presentationGate = SimulatorPresentationGate()
        private var presentationRecoveryTask: Task<Void, Never>?
        private var inFlightDrawables: Int { presentationGate.inFlight }
        private var presentationGeneration: Int { presentationGate.generation }
        private var dragging = false
        private var modifiers = Set<Int>()
        let measurements = SimulatorDisplayMeasurements()
        private var renderCounters = SimulatorRenderCounters()
        private let measure = CommandLine.arguments.contains("--e2e-test")
        private let lifecycle = CommandLine.arguments.contains("--e2e-test")
            ? SimulatorRenderLifecycle(historyLimit: CommandLine.arguments.contains("--e2e-simulator-frame-trace") ? 6000 : 64) : nil
        let frameTrace = CommandLine.arguments.contains("--e2e-test")
            && CommandLine.arguments.contains("--e2e-simulator-frame-trace") ? SimulatorFrameTrace() : nil
        var displaySyncEnabled: Bool { metalLayer.displaySyncEnabled }
        var displayCondition: SimulatorDisplayCondition? {
            guard let screen = window?.screen,
                let identifier = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return SimulatorDisplayCondition(
                displayID: identifier.uint32Value, maximumFPS: screen.maximumFramesPerSecond,
                contentsScale: metalLayer.contentsScale, drawableSize: metalLayer.drawableSize)
        }
        private var usesImmutableContents: Bool { immutableContentsEnabled && displayMode == .synchronized }
        var steadyPresentationObservable: Bool { !usesImmutableContents }
        var renderState: SimulatorRenderState {
            SimulatorRenderState(
                counters: renderCounters, inFlight: inFlightDrawables, generation: presentationGeneration,
                hasPendingFrame: pending != nil, hasCurrentFrame: current != nil, redrawNeeded: redrawNeeded,
                maximumDrawableCount: metalLayer.maximumDrawableCount,
                presentsWithTransaction: metalLayer.presentsWithTransaction, layerOpaque: metalLayer.isOpaque,
                drawableSize: metalLayer.drawableSize, contentsScale: metalLayer.contentsScale,
                firstInvalidGeometry: firstInvalidGeometry, lifecycle: lifecycle?.read(),
                renderer: usesImmutableContents ? "core-animation" : "metal",
                steadyPresentationObservable: steadyPresentationObservable,
                contentsVisible: !imageLayer.isHidden && imageLayer.contents != nil)
        }

        nonisolated override var isFlipped: Bool { true }
        nonisolated override var acceptsFirstResponder: Bool { true }

        init(metal: MTLDevice) throws {
            guard let queue = metal.makeCommandQueue() else {
                throw SimulatorFailure("Metal is unavailable")
            }
            self.metal = metal
            self.queue = queue
            let library = try metal.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "simulatorVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "simulatorFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try metal.makeRenderPipelineState(descriptor: descriptor)
            metalLayer = CAMetalLayer()
            metalLayer.device = metal
            metalLayer.pixelFormat = .bgra8Unorm
            metalLayer.maximumDrawableCount = 3
            metalLayer.displaySyncEnabled = true
            metalLayer.framebufferOnly = true
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            super.init(frame: .zero)
            let background = CALayer()
            background.backgroundColor = CGColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
            background.isGeometryFlipped = true
            background.addSublayer(metalLayer)
            imageLayer.contentsGravity = .resize
            imageLayer.isHidden = true
            background.addSublayer(imageLayer)
            layer = background
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        func setDisplayMode(_ mode: SimulatorDisplayMode) {
            guard !isClosed, mode != displayMode else { return }
            displayMode = mode
            metalLayer.displaySyncEnabled = mode == .synchronized
            invalidatePresentation()
            redrawNeeded = true
            drawLatestFrame()
        }

        func resetMeasurements() {
            measurements.reset()
            frameTrace?.reset()
            renderCounters = SimulatorRenderCounters()
            renderCounters.initialInFlight = inFlightDrawables
            renderCounters.maximumInFlight = inFlightDrawables
        }

        func receive(_ frame: CXSimulatorFrame) {
            guard !isClosed else {
                frame.finish()
                return
            }
            frameTrace?.record(metadata: frame.metadata, receivedAt: ProcessInfo.processInfo.systemUptime,
                deliveryTiming: frame.deliveryTiming)
            do {
                let nextGeometry = try geometryDecoder.decode(SimulatorGeometry.self, from: frame.metadataJSON)
                guard nextGeometry.isValid else {
                    if measure, firstInvalidGeometry == nil { firstInvalidGeometry = nextGeometry }
                    if geometry == nil, nextGeometry.isAwaitingOrientation {
                        frame.finish()
                        return
                    }
                    throw SimulatorFailure("Invalid simulator display geometry")
                }
                if geometry != nextGeometry {
                    geometry = nextGeometry
                    textures.removeAll(keepingCapacity: true)
                    invalidatePresentation()
                    updateGeometry()
                }
                guard visible else {
                    frame.finish()
                    return
                }
                if measure { renderCounters.receivedFrames += 1 }
                let surfaceID = IOSurfaceGetID(frame.surface)
                let texture: MTLTexture
                if let cached = textures[surfaceID] {
                    texture = cached
                } else {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm, width: nextGeometry.width, height: nextGeometry.height, mipmapped: false)
                    descriptor.storageMode = .shared
                    descriptor.usage = .shaderRead
                    guard let mapped = metal.makeTexture(descriptor: descriptor, iosurface: frame.surface, plane: 0) else {
                        throw SimulatorFailure("Cannot map the shared simulator frame")
                    }
                    if textures.count == 3 { textures.removeAll(keepingCapacity: true) }
                    textures[surfaceID] = mapped
                    texture = mapped
                }
                if measure, pending != nil { renderCounters.replacedPendingFrames += 1 }
                pending?.retire()
                pending = FrameLease(frame: frame, texture: texture)
                drawLatestFrame()
            } catch {
                frame.finish()
                onError(error.localizedDescription)
            }
        }

        override func layout() {
            super.layout()
            if measure { renderCounters.layoutCalls += 1 }
            updateVisibility()
            updateGeometry()
            redrawNeeded = true
            drawLatestFrame()
        }
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateGeometry()
            drawLatestFrame()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if !isClosed, let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                    NSWindow.didDeminiaturizeNotification, NSWindow.didMiniaturizeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility), name: name, object: window)
                }
            }
            updateVisibility()
        }

        @objc private func updateVisibility() {
            let next = !isClosed && window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
            guard next != visible else { return }
            visible = next
            if measure { visibilityChangedAt = ProcessInfo.processInfo.systemUptime }
            if !next {
                invalidatePresentation()
                pending?.retire()
                pending = nil
                current?.retire()
                current = nil
                textures.removeAll(keepingCapacity: true)
                receivedFrame = false
                inputReadyAt = 0
                cancelInput()
            }
            onVisibility(next)
        }

        private func updateGeometry() {
            guard !isClosed else { return }
            let scale = window?.backingScaleFactor ?? 2
            guard let geometry, bounds.width > 0, bounds.height > 0 else {
                viewport = .zero
                return
            }
            let layout = SimulatorContentsLayout(bounds: bounds, geometry: geometry)
            let nextViewport = layout.viewport
            let drawableSize = CGSize(width: nextViewport.width * scale, height: nextViewport.height * scale)
            if viewport != nextViewport || metalLayer.contentsScale != scale || metalLayer.drawableSize != drawableSize {
                invalidatePresentation()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                metalLayer.contentsScale = scale
                metalLayer.frame = nextViewport
                metalLayer.drawableSize = drawableSize
                CATransaction.commit()
                viewport = nextViewport
                redrawNeeded = true
                receivedFrame = false
                inputReadyAt = 0
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contentsScale = scale
            imageLayer.bounds = CGRect(origin: .zero, size: layout.contentsSize)
            imageLayer.position = CGPoint(x: nextViewport.midX, y: nextViewport.midY)
            imageLayer.setAffineTransform(layout.transform)
            CATransaction.commit()
        }

        private func invalidatePresentation() {
            if measure { renderCounters.invalidatedDrawables += inFlightDrawables }
            cancelPresentationRecovery()
            presentationGate.invalidate()
            receivedFrame = false
            inputReadyAt = 0
            cancelInput()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = nil
            imageLayer.isHidden = true
            metalLayer.isHidden = false
            CATransaction.commit()
            // AppKit commits at the display cycle; flushing here can reenter SwiftUI attachment.
        }

        private func promotePendingFrame() {
            guard let pending else { return }
            current?.retire()
            current = pending
            self.pending = nil
        }

        private func presentContents() {
            promotePendingFrame()
            guard let current else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = current.frame.surface
            imageLayer.isHidden = false
            metalLayer.isHidden = true
            CATransaction.commit()
            CATransaction.flush()
            if measure { renderCounters.contentsSubmissions += 1 }
            redrawNeeded = false
        }

        private func cancelPresentationRecovery() {
            presentationRecoveryTask?.cancel()
            presentationRecoveryTask = nil
        }

        private func schedulePresentationRecovery() {
            guard visible, presentationRecoveryTask == nil, presentationGate.allGPUCompleted else { return }
            let generation = presentationGeneration
            presentationRecoveryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.presentationGeneration == generation else { return }
                self.presentationRecoveryTask = nil
                guard self.presentationGate.needsRecovery(at: ProcessInfo.processInfo.systemUptime) else { return }
                self.redrawNeeded = true
                self.drawLatestFrame()
            }
        }

        private func drawLatestFrame() {
            guard visible, geometry != nil, viewport.width > 0,
                pending != nil || (redrawNeeded && current != nil) else { return }
            if usesImmutableContents && receivedFrame {
                presentContents()
                return
            }
            if inFlightDrawables >= metalLayer.maximumDrawableCount {
                guard presentationGate.needsRecovery(at: ProcessInfo.processInfo.systemUptime) else {
                    if measure { renderCounters.drawGateBlocked += 1 }
                    return
                }
                if measure { renderCounters.invalidatedDrawables += inFlightDrawables }
                cancelPresentationRecovery()
                presentationGate.invalidate()
                receivedFrame = false
                inputReadyAt = 0
                cancelInput()
            }
            autoreleasepool {
                let started = CACurrentMediaTime()
                guard let drawable = metalLayer.nextDrawable() else {
                    if measure { renderCounters.drawableUnavailable += 1 }
                    return
                }
                if measure { measurements.recordDrawableWait((CACurrentMediaTime() - started) * 1000) }
                render(drawable)
            }
        }

        private func render(_ drawable: CAMetalDrawable) {
            guard let geometry else { return }
            promotePendingFrame()
            guard let frame = current, let command = queue.makeCommandBuffer() else {
                return
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setViewport(
                MTLViewport(
                    originX: 0, originY: 0, width: Double(drawable.texture.width),
                    height: Double(drawable.texture.height), znear: 0, zfar: 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(frame.texture, index: 0)
            var orientation = UInt32(geometry.orientation)
            encoder.setFragmentBytes(&orientation, length: MemoryLayout<UInt32>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            let generation = presentationGeneration
            let encodedAt = measure ? ProcessInfo.processInfo.systemUptime : 0
            let gpuTimes: Mutex<[Double]?>? = measure ? Mutex(nil) : nil
            let lifecycle = lifecycle
            let lifecycleID = lifecycle?.submit(
                drawableID: drawable.drawableID, generation: generation, at: encodedAt,
                metadata: frame.frame.metadata, displayCondition: displayCondition)
            let presentationID = presentationGate.submit()
            if measure {
                renderCounters.submittedDrawables += 1
                renderCounters.maximumInFlight = max(renderCounters.maximumInFlight, inFlightDrawables)
            }
            drawable.addPresentedHandler { [weak self] drawable in
                let presentedAt = drawable.presentedTime
                let callbackAt = gpuTimes == nil ? 0 : ProcessInfo.processInfo.systemUptime
                let gpu = gpuTimes?.withLock { $0 }
                if let lifecycleID {
                    lifecycle?.presented(lifecycleID, at: presentedAt, callbackAt: callbackAt)
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let lifecycleID {
                        lifecycle?.presentationMainActor(lifecycleID, at: ProcessInfo.processInfo.systemUptime)
                    }
                    guard self.presentationGeneration == generation else {
                        if self.measure { self.renderCounters.staleCallbacks += 1 }
                        return
                    }
                    guard self.presentationGate.presented(presentationID, generation: generation) else { return }
                    self.cancelPresentationRecovery()
                    if self.measure {
                        self.renderCounters.presentedCallbacks += 1
                        if presentedAt <= 0 { self.renderCounters.discardedDrawables += 1 }
                    }
                    if let gpu {
                        self.measurements.recordRenderTimes([
                            encodedAt, gpu[0], gpu[1], presentedAt, callbackAt, ProcessInfo.processInfo.systemUptime,
                        ])
                    }
                    self.drawLatestFrame()
                }
            }
            frame.beginGPUUse()
            command.addCompletedHandler { [weak self] buffer in
                gpuTimes?.withLock { $0 = [buffer.gpuStartTime, buffer.gpuEndTime] }
                if let lifecycleID {
                    lifecycle?.completed(lifecycleID, start: buffer.gpuStartTime, end: buffer.gpuEndTime,
                        status: Int(buffer.status.rawValue), error: buffer.error?.localizedDescription,
                        callbackAt: ProcessInfo.processInfo.systemUptime)
                }
                Task { @MainActor [weak self] in
                    frame.endGPUUse()
                    self?.presentationGate.completed(presentationID, generation: generation, at: ProcessInfo.processInfo.systemUptime)
                    self?.schedulePresentationRecovery()
                    if let lifecycleID {
                        lifecycle?.completionMainActor(lifecycleID, at: ProcessInfo.processInfo.systemUptime)
                    }
                }
            }
            if !receivedFrame {
                let expectedViewport = viewport
                drawable.addPresentedHandler { [weak self] drawable in
                    guard drawable.presentedTime > 0 else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.visible, self.presentationGeneration == generation, self.geometry == geometry,
                            self.viewport == expectedViewport, !self.receivedFrame else { return }
                        self.receivedFrame = true
                        if self.measure { self.inputReadyAt = ProcessInfo.processInfo.systemUptime }
                        if self.usesImmutableContents {
                            self.redrawNeeded = true
                            self.drawLatestFrame()
                        }
                        self.onFirstFrame()
                    }
                }
            }
            if measure, let sourceAt = (frame.frame.metadata["sourceReadyAt"] as? NSNumber)?.doubleValue,
                let sequence = (frame.frame.metadata["sequence"] as? NSNumber)?.uint64Value
            {
                let measurements = measurements
                let sourceSequence = (frame.frame.metadata["sourceSequence"] as? NSNumber)?.uint64Value ?? sequence
                let capturedAt = (frame.frame.metadata["capturedAt"] as? NSNumber)?.doubleValue ?? sourceAt
                let copiedAt = (frame.frame.metadata["copyReadyAt"] as? NSNumber)?.doubleValue ?? capturedAt
                let receivedAt = frame.receivedAt
                let copyStages = frame.frame.metadata["copyStagesMs"] as? [Double]
                drawable.addPresentedHandler { drawable in
                    measurements.record(sequence: sequence, sourceSequence: sourceSequence,
                        times: [sourceAt, capturedAt, copiedAt, receivedAt, encodedAt, drawable.presentedTime],
                        copyStages: copyStages)
                }
            }
            command.present(drawable)
            command.commit()
            if let lifecycleID { lifecycle?.committed(lifecycleID, at: ProcessInfo.processInfo.systemUptime) }
            redrawNeeded = false
        }

        private func devicePoint(_ event: NSEvent) -> SimulatorPoint? {
            guard visible, receivedFrame, let geometry else { return nil }
            let point = convert(event.locationInWindow, from: nil)
            guard viewport.contains(point) else { return nil }
            return SimulatorPoint(
                x: (point.x - viewport.minX) / viewport.width * geometry.displayWidth,
                y: (point.y - viewport.minY) / viewport.height * geometry.displayHeight)
        }
        override func mouseDown(with event: NSEvent) {
            if measure { inputEventReceivedAt = ProcessInfo.processInfo.systemUptime }
            guard let point = devicePoint(event) else { return }
            window?.makeFirstResponder(self)
            dragging = true
            onTouch(point, 0)
        }
        override func mouseDragged(with event: NSEvent) {
            if measure { inputEventReceivedAt = ProcessInfo.processInfo.systemUptime }
            guard dragging, let point = devicePoint(event) else { return }
            onTouch(point, 1)
        }
        override func mouseUp(with event: NSEvent) {
            if measure { inputEventReceivedAt = ProcessInfo.processInfo.systemUptime }
            guard dragging else { return }
            dragging = false
            if let point = devicePoint(event) { onTouch(point, 2) } else { onTouch(SimulatorPoint(x: -1, y: -1), 2) }
        }
        override func keyDown(with event: NSEvent) {
            guard let usage = Self.keyUsages[event.keyCode] else { return }
            syncModifiers(event.modifierFlags)
            onKey(usage, true)
        }
        override func keyUp(with event: NSEvent) {
            guard let usage = Self.keyUsages[event.keyCode] else { return }
            syncModifiers(event.modifierFlags)
            onKey(usage, false)
        }

        private func syncModifiers(_ flags: NSEvent.ModifierFlags) {
            for (left, right, flag) in [(224, 228, NSEvent.ModifierFlags.control), (225, 229, .shift),
                (226, 230, .option), (227, 231, .command)] {
                if flags.contains(flag) {
                    if !modifiers.contains(left) && !modifiers.contains(right) {
                        modifiers.insert(left)
                        onKey(left, true)
                    }
                } else {
                    for usage in [left, right] where modifiers.remove(usage) != nil { onKey(usage, false) }
                }
            }
        }

        override func flagsChanged(with event: NSEvent) {
            let mapping: [UInt16: (Int, NSEvent.ModifierFlags)] = [
                59: (224, .control), 62: (228, .control), 56: (225, .shift), 60: (229, .shift),
                58: (226, .option), 61: (230, .option), 55: (227, .command), 54: (231, .command),
            ]
            guard let (usage, flag) = mapping[event.keyCode] else { return }
            let down = event.modifierFlags.contains(flag) && !modifiers.contains(usage)
            if down { modifiers.insert(usage) } else { modifiers.remove(usage) }
            onKey(usage, down)
        }
        override func resignFirstResponder() -> Bool {
            cancelInput()
            return super.resignFirstResponder()
        }
        private func cancelInput() {
            dragging = false
            modifiers.removeAll()
            onCancelInput()
        }

        private static let keyUsages: [UInt16: Int] = [
            0: 4, 11: 5, 8: 6, 2: 7, 14: 8, 3: 9, 5: 10, 4: 11, 34: 12, 38: 13, 40: 14,
            37: 15, 46: 16, 45: 17, 31: 18, 35: 19, 12: 20, 15: 21, 1: 22, 17: 23,
            32: 24, 9: 25, 13: 26, 7: 27, 16: 28, 6: 29, 18: 30, 19: 31, 20: 32,
            21: 33, 23: 34, 22: 35, 26: 36, 28: 37, 25: 38, 29: 39, 36: 40, 53: 41,
            51: 42, 48: 43, 49: 44, 27: 45, 24: 46, 33: 47, 30: 48, 42: 49, 41: 51,
            39: 52, 50: 53, 43: 54, 47: 55, 44: 56, 124: 79, 123: 80, 125: 81, 126: 82,
        ]
        func close() {
            guard !isClosed else { return }
            isClosed = true
            NotificationCenter.default.removeObserver(self)
            visible = false
            invalidatePresentation()
            receivedFrame = false
            inputReadyAt = 0
            pending?.retire()
            pending = nil
            current?.retire()
            current = nil
            textures.removeAll()
        }

        private static let shader = """
            #include <metal_stdlib>
            using namespace metal;
            struct V { float4 position [[position]]; float2 uv; };
            vertex V simulatorVertex(uint i [[vertex_id]]) {
                float2 positions[] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
                float2 coords[] = {float2(0,1),float2(2,1),float2(0,-1)};
                return {float4(positions[i],0,1),coords[i]};
            }
            fragment float4 simulatorFragment(V v [[stage_in]], texture2d<float> image [[texture(0)]], constant uint &orientation [[buffer(0)]]) {
                float2 p = v.uv;
                if (orientation == 2) p = 1-p;
                else if (orientation == 3) p = float2(1-p.y,p.x);
                else if (orientation == 4) p = float2(p.y,1-p.x);
                constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
                return image.sample(s,p);
            }
            """
    }

    struct SimulatorContentsLayout: Sendable {
        let viewport: CGRect
        let contentsSize: CGSize
        let transform: CGAffineTransform

        init(bounds: CGRect, geometry: SimulatorGeometry) {
            let fit = min(bounds.width / geometry.displayWidth, bounds.height / geometry.displayHeight)
            let size = CGSize(width: geometry.displayWidth * fit, height: geometry.displayHeight * fit)
            viewport = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                width: size.width, height: size.height)
            contentsSize = CGSize(width: Double(geometry.width) / geometry.scale * fit,
                height: Double(geometry.height) / geometry.scale * fit)
            let angle: Double
            switch geometry.orientation {
            case 2: angle = .pi
            case 3: angle = -.pi / 2
            case 4: angle = .pi / 2
            default: angle = 0
            }
            transform = CGAffineTransform(rotationAngle: angle)
        }
    }

    struct SimulatorPresentationGate: Sendable {
        private struct Submission: Sendable {
            var completedAt: Double?
        }

        private var submissions: [Int: Submission] = [:]
        private var nextID = 0
        private(set) var generation = 0
        var inFlight: Int { submissions.count }
        var allGPUCompleted: Bool {
            submissions.count >= 2 && submissions.values.allSatisfy { $0.completedAt != nil }
        }

        mutating func submit() -> Int {
            nextID += 1
            submissions[nextID] = Submission()
            return nextID
        }

        mutating func completed(_ id: Int, generation: Int, at: Double) {
            guard generation == self.generation else { return }
            submissions[id]?.completedAt = at
        }

        mutating func presented(_ id: Int, generation: Int) -> Bool {
            guard generation == self.generation else { return false }
            return submissions.removeValue(forKey: id) != nil
        }

        func needsRecovery(at: Double) -> Bool {
            guard submissions.count >= 2 else { return false }
            return submissions.values.allSatisfy { submission in
                guard let completedAt = submission.completedAt else { return false }
                return at - completedAt >= 0.25
            }
        }

        mutating func invalidate() {
            generation += 1
            submissions.removeAll(keepingCapacity: true)
        }
    }

    final class SimulatorRenderLifecycle: Sendable {
        struct Row: Sendable {
            let id: Int
            let drawableID: Int
            let generation: Int
            let sequence: UInt64?
            let sourceSequence: UInt64?
            let submittedAt: Double
            let displayCondition: SimulatorDisplayCondition?
            var commitReturnedAt = 0.0
            var gpuStartedAt = 0.0
            var gpuEndedAt = 0.0
            var gpuCallbackAt = 0.0
            var gpuMainActorAt = 0.0
            var gpuStatus = 0
            var error: String?
            var presentedAt = 0.0
            var presentationCallbackAt = 0.0
            var presentationMainActorAt = 0.0
        }

        struct Sample: Sendable {
            let historyLimit: Int
            var submitted = 0
            var completed = 0
            var failed = 0
            var presentationCallbacks = 0
            var rows: [Row] = []

            var overwrittenRows: Int { submitted - rows.count }

            mutating func updateRow(_ id: Int, _ update: (inout Row) -> Void) {
                guard id > 0 else { return }
                let index = (id - 1) % historyLimit
                guard rows.indices.contains(index), rows[index].id == id else { return }
                update(&rows[index])
            }
        }

        private let sample: Mutex<Sample>

        init(historyLimit: Int = 64) {
            precondition(historyLimit > 0)
            sample = Mutex(Sample(historyLimit: historyLimit))
        }

        func submit(
            drawableID: Int, generation: Int, at: Double, metadata: [String: Any],
            displayCondition: SimulatorDisplayCondition? = nil
        ) -> Int {
            let sequence = (metadata["sequence"] as? NSNumber)?.uint64Value
            let sourceSequence = (metadata["sourceSequence"] as? NSNumber)?.uint64Value
            return sample.withLock { sample in
                sample.submitted += 1
                let row = Row(id: sample.submitted, drawableID: drawableID,
                    generation: generation, sequence: sequence, sourceSequence: sourceSequence, submittedAt: at,
                    displayCondition: displayCondition)
                if sample.rows.count < sample.historyLimit {
                    sample.rows.append(row)
                } else {
                    sample.rows[(sample.submitted - 1) % sample.historyLimit] = row
                }
                return sample.submitted
            }
        }

        func committed(_ id: Int, at: Double) {
            sample.withLock { sample in
                sample.updateRow(id) { $0.commitReturnedAt = at }
            }
        }

        func completed(_ id: Int, start: Double, end: Double, status: Int, error: String?, callbackAt: Double) {
            sample.withLock { sample in
                sample.completed += 1
                if status != Int(MTLCommandBufferStatus.completed.rawValue) { sample.failed += 1 }
                sample.updateRow(id) { row in
                    row.gpuStartedAt = start
                    row.gpuEndedAt = end
                    row.gpuCallbackAt = callbackAt
                    row.gpuStatus = status
                    row.error = error
                }
            }
        }

        func completionMainActor(_ id: Int, at: Double) {
            sample.withLock { sample in
                sample.updateRow(id) { $0.gpuMainActorAt = at }
            }
        }

        func presented(_ id: Int, at: Double, callbackAt: Double) {
            sample.withLock { sample in
                sample.presentationCallbacks += 1
                sample.updateRow(id) { row in
                    row.presentedAt = at
                    row.presentationCallbackAt = callbackAt
                }
            }
        }

        func presentationMainActor(_ id: Int, at: Double) {
            sample.withLock { sample in
                sample.updateRow(id) { $0.presentationMainActorAt = at }
            }
        }

        // Keep pre-interval pending submissions when display measurements reset.
        func read() -> Sample {
            sample.withLock { sample in
                var result = sample
                result.rows.sort { $0.id < $1.id }
                return result
            }
        }
    }

    final class SimulatorDisplayMeasurements: Sendable {
        struct Sample: Sendable {
            var frames = 0
            var firstTime = 0.0
            var lastTime = 0.0
            var sequence: UInt64 = 0
            var sourceSequence: UInt64 = 0
            var milliseconds: [Double] = []
            var stages: [[Double]] = Array(repeating: [], count: 5)
            var startedAt = 0.0
            var drawableWaits: [Double] = []
            var drawableAcquisitions = 0
            var copyStages: [[Double]] = Array(repeating: [], count: 4)
            var copyRecords = 0
            var renderStages: [[Double]] = Array(repeating: [], count: 5)
            var renderRecords = 0

            func elapsed(at time: Double) -> Double {
                let start = startedAt > 0 ? startedAt : firstTime
                return start > 0 ? max(0, time - start) : 0
            }

            func uniqueFPS(at time: Double) -> Double {
                let duration = elapsed(at: time)
                guard duration > 0 else { return 0 }
                let count = startedAt > 0 ? frames : max(0, frames - 1)
                return Double(count) / duration
            }
        }
        private let samples = Mutex(Sample())
        func recordRenderTimes(_ times: [Double]) {
            guard times.count == 6, times.allSatisfy({ $0.isFinite && $0 > 0 }),
                zip(times, times.dropFirst()).allSatisfy({ $0 <= $1 }) else { return }
            samples.withLock { sample in
                guard times[0] >= sample.startedAt else { return }
                let index = sample.renderRecords % 6000
                sample.renderRecords += 1
                for stage in 0..<5 {
                    let elapsed = (times[stage + 1] - times[stage]) * 1000
                    if sample.renderStages[stage].count < 6000 { sample.renderStages[stage].append(elapsed) }
                    else { sample.renderStages[stage][index] = elapsed }
                }
            }
        }
        func recordDrawableWait(_ milliseconds: Double) {
            samples.withLock { sample in
                let index = sample.drawableAcquisitions % 6000
                sample.drawableAcquisitions += 1
                if sample.drawableWaits.count < 6000 { sample.drawableWaits.append(milliseconds) }
                else { sample.drawableWaits[index] = milliseconds }
            }
        }
        func record(sequence: UInt64, sourceSequence: UInt64, times: [Double], copyStages: [Double]? = nil) {
            let sourceAt = times[0], presentedAt = times[5]
            guard presentedAt > 0, presentedAt >= sourceAt else { return }
            samples.withLock { sample in
                guard sourceAt >= sample.startedAt else { return }
                guard sequence != sample.sequence else { return }
                sample.sequence = sequence
                sample.sourceSequence = sourceSequence
                sample.frames += 1
                if sample.firstTime == 0 { sample.firstTime = presentedAt }
                sample.lastTime = presentedAt
                if let copyStages, copyStages.count == 4, copyStages.allSatisfy({ $0.isFinite && $0 >= 0 }) {
                    let index = sample.copyRecords % 6000
                    sample.copyRecords += 1
                    for stage in 0..<4 {
                        if sample.copyStages[stage].count < 6000 { sample.copyStages[stage].append(copyStages[stage]) }
                        else { sample.copyStages[stage][index] = copyStages[stage] }
                    }
                }
                if sample.milliseconds.count < 6000 {
                    sample.milliseconds.append((presentedAt - sourceAt) * 1000)
                    for index in 0..<5 { sample.stages[index].append((times[index + 1] - times[index]) * 1000) }
                } else {
                    let index = (sample.frames - 1) % 6000
                    sample.milliseconds[index] = (presentedAt - sourceAt) * 1000
                    for stage in 0..<5 { sample.stages[stage][index] = (times[stage + 1] - times[stage]) * 1000 }
                }
            }
        }
        func read() -> Sample { samples.withLock { $0 } }
        func reset() {
            samples.withLock { sample in
                sample = Sample(sequence: sample.sequence, sourceSequence: sample.sourceSequence, startedAt: CACurrentMediaTime())
            }
        }
    }

    @MainActor
    private final class FrameLease {
        let frame: CXSimulatorFrame
        let texture: MTLTexture
        let receivedAt = ProcessInfo.processInfo.systemUptime
        private var gpuUses = 0
        private var retired = false
        private var finished = false
        private var retirementTask: Task<Void, Never>?
        init(frame: CXSimulatorFrame, texture: MTLTexture) {
            self.frame = frame
            self.texture = texture
        }
        func beginGPUUse() { gpuUses += 1 }
        func endGPUUse() {
            gpuUses -= 1
            _ = finishIfUnused()
        }
        func retire() {
            retired = true
            guard !finishIfUnused(), retirementTask == nil else { return }
            // Keep the lease alive after the view closes until GPU and compositor reads finish.
            retirementTask = Task { @MainActor [self] in
                defer { retirementTask = nil }
                while !finishIfUnused() {
                    do { try await Task.sleep(for: .milliseconds(2)) } catch { return }
                }
            }
        }
        private func finishIfUnused() -> Bool {
            if finished { return true }
            guard retired && gpuUses == 0 && !IOSurfaceIsInUse(frame.surface) else { return false }
            finished = true
            frame.finish()
            return true
        }
    }
#endif
