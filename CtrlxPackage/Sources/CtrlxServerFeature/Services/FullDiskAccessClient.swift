#if os(macOS)
    import AppKit
    import Dependencies
    import DependenciesMacros

    @DependencyClient
    struct FullDiskAccessClient: Sendable {
        var openSettings: @MainActor @Sendable () throws -> Void
        var revealApplication: @MainActor @Sendable () throws -> Void
    }

    extension FullDiskAccessClient: DependencyKey {
        static let liveValue = Self(openSettings: {
            guard
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
                NSWorkspace.shared.open(url) else {
                throw FullDiskAccessError(message: "Could not open System Settings. Open Privacy & Security → Full Disk Access manually.")
            }
        }, revealApplication: {
            let application = Bundle.main.bundleURL
            guard application.pathExtension == "app" else {
                throw FullDiskAccessError(message: "Open this guide from the installed CtrlX app to locate it in Finder.")
            }
            NSWorkspace.shared.activateFileViewerSelecting([application])
        })
    }

    private struct FullDiskAccessError: LocalizedError {
        let message: String
        var errorDescription: String? {
            message
        }
    }
#endif
