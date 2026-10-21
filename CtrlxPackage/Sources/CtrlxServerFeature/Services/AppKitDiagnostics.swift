import AppKit
import CtrlxBrowserBridge
import CtrlxCommon
import Dependencies
import OSLog

struct AppKitWindowDiagnosticContext {
    enum Kind: String { case main, detached }

    let kind: Kind
    let connection: ConnectedViewer.ConnectionState
    let paired: Bool
    let remote: Bool
    var split = false
    var browserSelected = false
    var fileSelected = false
    var rightPaneFocused = false
    var rightBrowserSelected = false
    var orderedTabCount = 0
    var browserTabCount = 0
    var fileTabCount = 0

    var snapshot: NSDictionary {
        let state = switch connection {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .reconnecting: "reconnecting"
        case .error: "error"
        }
        return [
            "kind": kind.rawValue, "toolbarConnection": state, "paired": paired, "remoteSelection": remote,
            "split": split, "browserSelected": browserSelected, "fileSelected": fileSelected,
            "rightPaneFocused": rightPaneFocused, "rightBrowserSelected": rightBrowserSelected,
            "orderedTabCount": orderedTabCount, "browserTabCount": browserTabCount, "fileTabCount": fileTabCount,
        ]
    }
}

/// Captures only cached geometry, never asks the failing window to lay out again.
@MainActor
final class AppKitDiagnostics: NSObject, @preconcurrency CXApplicationDiagnosticsDelegate {
    static let shared = AppKitDiagnostics()

    private let contexts = NSMapTable<NSWindow, NSDictionary>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let windows: @MainActor () -> [NSWindow]
    private var recordedLayoutFailure = false
    private let logger = Logger(subsystem: "com.ctrlx.appkit", category: "Diagnostics")
    @Dependency(AppKitDiagnosticStore.self) private var store
    @Dependency(BrowserDiagnosticStore.self) private var browserStore
    private var debugEnabled = false
    private var browserWriteFailed = false

    init(windows: @escaping @MainActor () -> [NSWindow] = { NSApp?.windows ?? [] }) {
        self.windows = windows
        super.init()
    }

    func setContext(_ context: AppKitWindowDiagnosticContext?, for window: NSWindow) {
        if let context {
            contexts.setObject(context.snapshot, forKey: window)
        } else {
            contexts.removeObject(forKey: window)
        }
    }

    func bind(to settings: AppSettings) {
        settings.onDebugModeChanged = { [weak self] in self?.setDebugMode($0) }
        setDebugMode(settings.debugModeEnabled)
    }

    func setDebugMode(_ enabled: Bool) {
        guard enabled != debugEnabled else { return }
        if !enabled {
            recordBrowserDiagnostic(["event": "debug-disabled"])
        }
        debugEnabled = enabled
        browserWriteFailed = false
        CXBrowserSetDebugMode(enabled)
        if enabled {
            recordBrowserDiagnostic(["event": "debug-enabled"])
        }
    }

    func recordBrowserDiagnostic(_ event: [String: Any]) {
        guard debugEnabled, !browserWriteFailed else { return }
        let build = AppBuildInfo.current
        let allWindows = windows()
        let report: [String: Any] = [
            "schemaVersion": 1,
            "timestamp": Date().ISO8601Format(),
            "uptimeSeconds": ProcessInfo.processInfo.systemUptime,
            "processID": ProcessInfo.processInfo.processIdentifier,
            "version": build.version ?? "unknown",
            "buildNumber": build.buildNumber ?? "unknown",
            "buildStamp": build.buildStamp ?? "unknown",
            "sourceRevision": build.sourceRevision ?? "unknown",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "memory": browserStore.memory(),
            "browser": event,
            "windowCount": allWindows.count,
            // Cached metadata only; no SwiftUI body evaluation, layout or view-tree walk.
            "windows": allWindows.prefix(16).map { window -> [String: Any] in
                [
                    "windowNumber": window.windowNumber, "frame": NSStringFromRect(window.frame),
                    "visible": window.isVisible, "key": window.isKeyWindow,
                    "toolbarItemCount": window.toolbar?.items.count ?? 0,
                    "context": contexts.object(forKey: window) ?? ["kind": "other"],
                ]
            },
        ]
        do {
            try browserStore.append(JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]))
        } catch {
            browserWriteFailed = true
            CXBrowserSetDebugMode(false)
            logger.error("Browser diagnostic collection stopped after a write failure: \(String(describing: error), privacy: .private)")
        }
    }

    func recordAppKitException(_ exception: NSException) {
        guard !recordedLayoutFailure else { return }
        let stack = exception.callStackSymbols
        guard Self.isLayoutFailure(stack) else { return }
        // Set before inspecting any views: reporting can itself reenter AppKit.
        recordedLayoutFailure = true
        do {
            let report = snapshot(exceptionName: exception.name.rawValue, stack: stack)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            let path = try store.write(data)
            logger.error("Saved AppKit layout diagnostic: \(path.path, privacy: .public)")
        } catch {
            logger.error("Could not save AppKit layout diagnostic: \(String(describing: error), privacy: .private)")
        }
    }

    static func isLayoutFailure(_ stack: [String]) -> Bool {
        stack.contains {
            $0.contains("_postWindowNeedsUpdateConstraints") || $0.contains("_postWindowNeedsLayout") || $0.contains("NSToolbar")
        }
    }

    func snapshot(exceptionName: String, stack: [String]) -> [String: Any] {
        let toolbarWindows = windows().filter { $0.toolbar != nil }
        let build = AppBuildInfo.current
        return [
            "schemaVersion": 1,
            "timestamp": Date().ISO8601Format(),
            "processID": ProcessInfo.processInfo.processIdentifier,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "version": build.version ?? "unknown",
            "buildNumber": build.buildNumber ?? "unknown",
            "buildStamp": build.buildStamp ?? "unknown",
            "sourceRevision": build.sourceRevision ?? "unknown",
            "exceptionName": String(exceptionName.prefix(256)),
            // Exception reasons/userInfo, window titles, labels and content are intentionally omitted.
            "stack": stack.prefix(80).map { String($0.prefix(1_024)) },
            "toolbarWindowCount": toolbarWindows.count,
            "windows": toolbarWindows.prefix(16).map(windowSnapshot),
        ]
    }

    private func windowSnapshot(_ window: NSWindow) -> [String: Any] {
        let items = window.toolbar?.items ?? []
        return [
            "object": Self.objectReference(window),
            "windowNumber": window.windowNumber,
            "frame": NSStringFromRect(window.frame),
            "visible": window.isVisible,
            "key": window.isKeyWindow,
            "main": window.isMainWindow,
            "styleMask": window.styleMask.rawValue,
            "toolbarStyle": window.toolbarStyle.rawValue,
            "context": contexts.object(forKey: window) ?? ["kind": "other"],
            "itemCount": items.count,
            "items": items.prefix(64).enumerated().map { index, item -> [String: Any] in
                var ancestors: [[String: Any]] = []
                var view = item.view
                // Include the native NSToolbarItemViewer so its address can be
                // matched to AppKit's nonconverging-layout warning.
                while let current = view, ancestors.count < 6 {
                    ancestors.append(Self.viewSnapshot(current))
                    view = current.superview
                }
                return [
                    "index": index,
                    "identifier": item.itemIdentifier.rawValue,
                    "object": Self.objectReference(item),
                    "enabled": item.isEnabled,
                    "views": ancestors,
                ]
            },
        ]
    }

    private static func viewSnapshot(_ view: NSView) -> [String: Any] {
        [
            "object": objectReference(view),
            "frame": NSStringFromRect(view.frame),
            "bounds": NSStringFromRect(view.bounds),
            "hidden": view.isHidden,
            "needsLayout": view.needsLayout,
            "needsUpdateConstraints": view.needsUpdateConstraints,
            "constraintCount": view.constraints.count,
            "constraints": view.constraints.prefix(32).map { constraint -> [String: Any] in
                [
                    "firstItem": objectReference(constraint.firstItem),
                    "firstAttribute": constraint.firstAttribute.rawValue,
                    "relation": constraint.relation.rawValue,
                    "secondItem": objectReference(constraint.secondItem),
                    "secondAttribute": constraint.secondAttribute.rawValue,
                    "constant": String(describing: constraint.constant),
                    "multiplier": String(describing: constraint.multiplier),
                    "priority": constraint.priority.rawValue,
                    "active": constraint.isActive,
                ]
            },
        ]
    }

    private static func objectReference(_ object: AnyObject?) -> [String: String] {
        guard let object else { return [:] }
        return [
            "class": String(describing: type(of: object)),
            "address": String(describing: Unmanaged.passUnretained(object).toOpaque()),
        ]
    }
}
