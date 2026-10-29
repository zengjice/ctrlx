#if os(macOS)
    import AppKit
    import CoreServices
    import Dependencies
    import DependenciesMacros
    import UniformTypeIdentifiers

    struct IPAFileAssociation: Equatable, Sendable, Identifiable {
        let applicationName: String
        let isCtrlX: Bool
        var id: String {
            applicationName
        }
    }

    @DependencyClient
    struct IPAFileAssociationClient: Sendable {
        var current: @MainActor @Sendable () throws -> IPAFileAssociation
        var setDefault: @MainActor @Sendable () async throws -> Void

        @MainActor
        func setDefaultAndVerify() async throws -> IPAFileAssociation {
            try Task.checkCancellation()
            do {
                try await setDefault()
            } catch {
                let systemError = error as NSError
                if
                    (systemError.domain == NSCocoaErrorDomain && systemError.code == NSUserCancelledError)
                    || (systemError.domain == NSOSStatusErrorDomain && systemError.code == Int(userCanceledErr)) {
                    throw CancellationError()
                }
                throw error
            }
            // Closing the SwiftUI prompt stops waiting here, not the system request.
            try Task.checkCancellation()
            let result = try current()
            guard result.isCtrlX else {
                throw IPAInstallationError(message: "macOS has not changed the default IPA application. Please try again.")
            }
            return result
        }
    }

    extension IPAFileAssociationClient: DependencyKey {
        static let ipaType = UTType(importedAs: "com.apple.itunes.ipa")

        static let liveValue = Self(current: {
            let url = NSWorkspace.shared.urlForApplication(toOpen: ipaType)
            let bundle = url.flatMap(Bundle.init(url:))
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? url?.deletingPathExtension().lastPathComponent ?? "None"
            return IPAFileAssociation(applicationName: name, isCtrlX: bundle?.bundleIdentifier != nil && bundle?.bundleIdentifier == Bundle.main.bundleIdentifier)
        }, setDefault: {
            guard Bundle.main.bundleURL.pathExtension == "app", !CommandLine.arguments.contains("--e2e-test") else {
                throw IPAInstallationError(message: "Set the default IPA application from the installed CtrlX app.")
            }
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: ipaType)
        })
    }
#endif
