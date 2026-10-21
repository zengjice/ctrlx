#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    struct TerminalAppearanceSettingsView: View {
        @Environment(IOSSettings.self) private var settings

        private static let availableFonts = ["Menlo", "SF Mono", "Courier New", "Monaco", "Courier"]

        var body: some View {
            @Bindable var settings = settings

            Form {
                Section("App Appearance") {
                    Picker("App Theme", selection: $settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Section {
                    Picker("Terminal Theme", selection: $settings.terminalTheme) {
                        ForEach(TerminalTheme.allCases, id: \.self) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    .accessibilityIdentifier("terminal-theme-picker")

                    Picker("Font", selection: $settings.terminalFontName) {
                        ForEach(Self.availableFonts, id: \.self) { font in
                            Text(font).tag(font)
                        }
                    }

                    VStack(alignment: .leading) {
                        LabeledContent("Font Size", value: "\(Int(settings.terminalFontSize)) pt")
                        Slider(value: $settings.terminalFontSize, in: 6...20, step: 1)
                            .accessibilityLabel("Font Size")
                            .accessibilityValue("\(Int(settings.terminalFontSize)) points")
                    }
                } header: {
                    Text("Terminal Display")
                } footer: {
                    Text("Terminal colors and font apply only to this device, independently of the app theme. Agent output may also use its own colors.")
                }
            }
            .navigationTitle("Appearance & Terminal")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    struct TerminalInputSettingsView: View {
        @Environment(IOSSettings.self) private var settings

        var body: some View {
            @Bindable var settings = settings

            Form {
                Section("Keyboard") {
                    Picker("Button Position", selection: $settings.terminalKeyboardControlPosition) {
                        ForEach(TerminalKeyboardControlPosition.allCases, id: \.self) { position in
                            Text(position.displayName).tag(position)
                        }
                    }

                    Toggle("Show Keyboard on Entry", isOn: $settings.showTerminalKeyboardOnEntry)
                        .accessibilityIdentifier("terminal-keyboard-on-entry-toggle")
                }

                Section {
                    Toggle("Agent Quick Input", isOn: $settings.agentQuickInputEnabled)
                } header: {
                    Text("Agent Input")
                } footer: {
                    Text("Show a reply field above Agent terminals.")
                }

                Section {
                    Toggle("Confirm Before Sending Images", isOn: $settings.confirmImageUploads)
                        .accessibilityIdentifier("confirm-image-uploads-toggle")
                } header: {
                    Text("Images")
                } footer: {
                    Text("Review selected images before uploading them to the Host.")
                }
            }
            .navigationTitle("Keyboard & Input")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    struct NewSessionSettingsView: View {
        @Environment(IOSSettings.self) private var settings

        var body: some View {
            @Bindable var settings = settings

            Form {
                Section {
                    TextField("Session Name", text: $settings.newSessionName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Default Name")
                } footer: {
                    Text("If the name already exists, a number is appended.")
                }

                Section {
                    Toggle("Automatically Fit to Screen", isOn: $settings.newSessionAutoFit)

                    if !settings.newSessionAutoFit {
                        Stepper("Width: \(settings.newSessionWidth) columns", value: $settings.newSessionWidth, in: 40...300, step: 10)
                        Stepper("Height: \(settings.newSessionHeight) rows", value: $settings.newSessionHeight, in: 10...100, step: 5)
                    }
                } header: {
                    Text("Initial Size")
                } footer: {
                    Text("Fit new sessions once using this device's viewport and font. Hosts without Fit support use 120 × 40. The size applies to the Host and all Viewers; existing sessions are unchanged.")
                }
            }
            .navigationTitle("New Session Defaults")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
#endif
