import AppKit
import Observation
import SwiftUI

/// No device access or Launch Services writes. Only the application's external
/// file routing and native SwiftUI window scenes are under test.
struct IPAFileAssociation: Identifiable {
    var applicationName = "CtrlX"
    var isCtrlX = true
    var id: String {
        applicationName
    }
}

struct IPAFileAssociationClient {
    func current() throws -> IPAFileAssociation {
        .init()
    }

    func setDefaultAndVerify() async throws -> IPAFileAssociation {
        .init()
    }
}

@propertyWrapper
struct Dependency {
    var wrappedValue = IPAFileAssociationClient()
    init(_: IPAFileAssociationClient.Type) { }
}

struct Logger {
    init(label _: String) { }
    func warning(_ message: String) {
        record("warning\t" + message)
    }
}

@MainActor @Observable
final class AppSettings { var askToHandleIPAFiles = true }

func record(_ line: String) {
    let path = Bundle.main.object(forInfoDictionaryKey: "CtrlXProbeLog") as! String
    let file = try! FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? file.close() }
    file.seekToEndOfFile()
    file.write(Data((line + "\n").utf8))
}

struct IPAInstallerView: View {
    let initialURL: URL?
    init(initialURL: URL? = nil, onChooseFile _: @escaping (URL) -> Void = { _ in }) {
        self.initialURL = initialURL
    }

    var body: some View {
        Text(initialURL?.path ?? "Choose IPA")
            .padding()
            .task {
                if let initialURL {
                    record("opened\t" + initialURL.path)
                }
            }
    }
}

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    /// PRODUCTION_DELEGATE
    func applicationDidFinishLaunching(_: Notification) {
        record("pid\t\(ProcessInfo.processInfo.processIdentifier)")
    }
}

@main
struct IPAFileOpenProbe: App {
    @NSApplicationDelegateAdaptor private var delegate: ProbeDelegate
    @State private var integration: IPAFileIntegration
    init() {
        let integration = IPAFileIntegration()
        _integration = State(initialValue: integration)
        delegate.onOpenFiles = { integration.receive($0) }
    }

    var body: some Scene {
        IPAInstallerScene()
        MenuBarExtra {
            Text("Isolated IPA routing test")
        } label: {
            Text("IPA Test").handleIPAFileRequests(integration)
        }
    }
}
