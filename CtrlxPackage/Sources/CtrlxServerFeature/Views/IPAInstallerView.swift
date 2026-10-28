#if os(macOS)
    import AppKit
    import CtrlxCommon
    import Dependencies
    import SwiftUI
    import UniformTypeIdentifiers

    public struct IPAInstallerScene: Scene {
        public static let windowID = "ipa-installer"
        static let fileWindowID = "ipa-installer-file"
        public init() { }

        public var body: some Scene {
            Window("Install IPA on iPhone", id: Self.windowID) {
                IPAInstallerView()
            }
            .defaultSize(width: 580, height: 530)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)

            WindowGroup("Install IPA on iPhone", id: Self.fileWindowID, for: URL.self) { file in
                IPAInstallerView(initialURL: file.wrappedValue, onChooseFile: { file.wrappedValue = $0 })
            }
            .defaultSize(width: 580, height: 530)
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
        }
    }

    public struct IPAInstallerCommands: Commands {
        @Environment(\.openWindow) private var openWindow
        public init() { }

        public var body: some Commands {
            CommandGroup(after: .importExport) {
                Button("Install IPA on iPhone…") {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: IPAInstallerScene.windowID)
                    NSApp.activate()
                }
                .accessibilityIdentifier("open-ipa-installer")
            }
        }
    }

    @MainActor
    struct IPAInstallerView: View {
        @Dependency(IPAInstallerClient.self) private var client
        private let onChooseFile: (URL) -> Void
        @State private var file: URL?
        @State private var package: IPAInstallationPackage?
        @State private var devices: [IPAInstallationDevice] = []
        @State private var selectedDeviceID: String?
        @State private var showsImporter = false
        @State private var isInspecting = false
        @State private var isLoadingDevices = false
        @State private var isInstalling = false
        @State private var refresh = 0
        @State private var request: InstallRequest?
        @State private var message: String?
        @State private var showsInstallationResult = false
        @State private var installationSucceeded = false
        @State private var deviceMessage: String?
        @State private var log = ""

        private struct InstallRequest: Identifiable {
            let id = UUID()
            let file: URL
            let package: IPAInstallationPackage
            let device: IPAInstallationDevice
        }

        init(initialURL: URL? = nil, onChooseFile: @escaping (URL) -> Void = { _ in }) {
            _file = State(initialValue: initialURL)
            self.onChooseFile = onChooseFile
        }

        var body: some View {
            VStack(spacing: 0) {
                Form {
                    Section("IPA on This Mac") {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(file?.lastPathComponent ?? "Choose an IPA file")
                                if let file {
                                    Text(file.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2).textSelection(.enabled)
                                }
                            }
                            Spacer()
                            Button("Choose IPA…") { showsImporter = true }
                                .disabled(isInstalling)
                                .accessibilityIdentifier("ipa-choose-file")
                        }
                        if isInspecting {
                            ProgressView("Reading package…")
                        }
                        if let package {
                            LabeledContent("App", value: package.name)
                            LabeledContent("Bundle ID", value: package.bundleID)
                            LabeledContent("Version", value: package.version)
                            LabeledContent("Size", value: package.bytes.formatted(.byteCount(style: .file)))
                        }
                    }
                    Section("iPhone Connected to This Mac") {
                        Picker("USB Device", selection: $selectedDeviceID) {
                            Text("Select a device").tag(String?.none)
                            ForEach(devices) { device in
                                Text(device.name + (device.systemVersion.map { " · iOS \($0)" } ?? ""))
                                    .tag(Optional(device.id))
                            }
                        }
                        .disabled(isInstalling || isLoadingDevices)
                        .accessibilityIdentifier("ipa-device-picker")
                        HStack {
                            if isLoadingDevices {
                                ProgressView().controlSize(.small)
                            }
                            if devices.isEmpty, !isLoadingDevices {
                                Text("Connect your iPhone by USB, unlock it and trust this Mac.")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Refresh Devices") { refresh += 1 }
                                .disabled(isInstalling || isLoadingDevices)
                                .accessibilityIdentifier("ipa-refresh-devices")
                        }
                        if let deviceMessage {
                            Text(deviceMessage).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("Installs locally, including in Viewer mode. The IPA must be signed for this device; iOS may require Developer Mode or developer trust.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                if let message {
                    Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal).padding(.bottom, 8)
                        .accessibilityIdentifier("ipa-installation-result")
                }
                if !log.isEmpty {
                    ScrollView {
                        Text(log.replacingOccurrences(of: "\r", with: "\n"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .frame(height: 130)
                    .background(.background.secondary)
                    .accessibilityIdentifier("ipa-installation-log")
                }
                Divider()
                HStack {
                    if isInstalling {
                        ProgressView().controlSize(.small)
                        Text("Installing…")
                        Spacer()
                        Button("Stop Waiting") { request = nil }
                    } else {
                        Spacer()
                        Button("Install") {
                            guard let file, let package, let device = devices.first(where: { $0.id == selectedDeviceID }) else { return }
                            isInstalling = true
                            message = nil
                            log = ""
                            request = .init(file: file, package: package, device: device)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(installationSucceeded || package == nil || selectedDeviceID == nil || isInspecting || isLoadingDevices)
                        .accessibilityIdentifier("ipa-install")
                    }
                }.padding()
            }
            .frame(minWidth: 520, minHeight: 470)
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .archive]) { result in
                switch result {
                case let .success(url):
                    file = url
                    onChooseFile(url)
                case let .failure(error): message = error.localizedDescription
                }
            }
            .alert(installationSucceeded ? "Installation Complete" : "Installation Failed", isPresented: $showsInstallationResult) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(message ?? "")
            }
            .onDisappear {
                installationSucceeded = false
            }
            .task(id: file) { await inspectFile() }
            .task(id: refresh) { await refreshDevices() }
            .task(id: request?.id) {
                guard let request else { return }
                defer {
                    isInstalling = false
                    self.request = nil
                }
                do {
                    try await client.install(request.file, request.package, request.device.id) { text in
                        log = String((log + text).suffix(64 * 1_024))
                    }
                    try Task.checkCancellation()
                    message = "Installed \(request.package.name) on \(request.device.name)."
                    installationSucceeded = true
                    showsInstallationResult = true
                } catch is CancellationError {
                    message = "Stopped waiting. The iPhone may still finish installation; check it before trying again."
                } catch {
                    message = error.localizedDescription
                    installationSucceeded = false
                    showsInstallationResult = true
                }
            }
        }

        private func inspectFile() async {
            package = nil
            message = nil
            log = ""
            guard let file else { return }
            isInspecting = true
            defer {
                if !Task.isCancelled {
                    isInspecting = false
                }
            }
            do {
                let result = try await client.inspect(file)
                guard !Task.isCancelled else { return }
                package = result
            } catch {
                if !Task.isCancelled {
                    message = error.localizedDescription
                }
            }
        }

        private func refreshDevices() async {
            isLoadingDevices = true
            deviceMessage = nil
            defer {
                if !Task.isCancelled {
                    isLoadingDevices = false
                }
            }
            do {
                let result = try await client.devices()
                guard !Task.isCancelled else { return }
                devices = result
                if !devices.contains(where: { $0.id == selectedDeviceID }) {
                    selectedDeviceID = devices.count == 1 ? devices.first?.id : nil
                }
            } catch {
                if !Task.isCancelled {
                    deviceMessage = error.localizedDescription
                }
            }
        }
    }
#endif
