#if os(macOS)
    import Dependencies
    import Foundation
    import Logging
    import Observation

    /// Retains open-file events during launch and checks the association once per app run.
    @MainActor @Observable
    final public class IPAFileIntegration {
        var pendingFiles: [URL] = []
        var defaultApplicationPrompt: IPAFileAssociation?
        private var checkedDefault = false
        @ObservationIgnored @Dependency(IPAFileAssociationClient.self) private var association
        private let logger = Logger(label: "com.jicezeng.ctrlx.ipa")

        public init() { }

        public func receive(_ urls: [URL]) {
            for url in urls where url.isFileURL && url.pathExtension.lowercased() == "ipa" {
                let file = url.standardizedFileURL
                if !pendingFiles.contains(file) {
                    pendingFiles.append(file)
                }
            }
        }

        func takeFiles() -> [URL] {
            let files = pendingFiles
            pendingFiles.removeAll()
            return files
        }

        func checkDefaultApplication(remind: Bool) {
            guard !checkedDefault else { return }
            checkedDefault = true
            guard remind, !CommandLine.arguments.contains("--e2e-test") else { return }
            do {
                let current = try association.current()
                if !current.isCtrlX {
                    defaultApplicationPrompt = current
                }
            } catch {
                logger.warning("Could not check the default IPA application: \(error.localizedDescription)")
            }
        }
    }
#endif
