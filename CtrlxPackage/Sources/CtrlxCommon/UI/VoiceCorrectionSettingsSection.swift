#if os(iOS) || os(macOS)
    import SwiftUI

    public struct VoiceCorrectionSettingsSection: View {
        @Bindable private var settings: VoiceCorrectionSettings
        @State private var model = VoiceCorrectionSettingsModel()
        @Environment(\.scenePhase) private var scenePhase
        @State private var isAPIKeyVisible = false

        public init(settings: VoiceCorrectionSettings) {
            self.settings = settings
        }

        public var body: some View {
            Section {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(VoiceCorrectionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .disabled(model.isBusy)

                LabeledContent("Provider Correction") {
                    Text(model.credentialStatus.label)
                        .foregroundStyle(model.hasStoredAPIKey ? Color.secondary : .orange)
                }
                LabeledContent("On-Device Correction") {
                    Text(model.onDeviceAvailability?.label ?? "Checking…")
                        .foregroundStyle(model.onDeviceAvailability?.isAvailable == true ? Color.secondary : .orange)
                }
                if model.credentialStatus == .missing, model.onDeviceAvailability?.isAvailable == false {
                    Text("Only speech transcription is available. Save an API key to enable context-aware correction.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("voice-correction-unavailable")
                }

                HStack {
                    Group {
                        if isAPIKeyVisible {
                            TextField("API key", text: $model.apiKeyDraft)
                        } else {
                            SecureField("API key", text: $model.apiKeyDraft)
                        }
                    }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .privacySensitive()

                    Button {
                        isAPIKeyVisible.toggle()
                    } label: {
                        Label(
                            isAPIKeyVisible ? "Hide API Key" : "Show API Key",
                            symbol: isAPIKeyVisible ? .eyeSlash : .eye
                        )
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
                .disabled(model.isBusy)

                Button {
                    isAPIKeyVisible = false
                    Task {
                        await model.saveAPIKey(settings: settings)
                    }
                } label: {
                    if model.isLoading {
                        HStack {
                            ProgressView()
                            Text("Saving")
                        }
                    } else {
                        Text("Save API Key")
                    }
                }
                .disabled(
                    model.isBusy
                        || model.apiKeyDraft
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )

                LabeledContent("Model List") {
                    Text(model.hasTestedModels ? "Tested" : "Recommended")
                        .foregroundStyle(.secondary)
                }

                if !model.models.isEmpty {
                    Picker("Model", selection: $settings.modelID) {
                        ForEach(model.models, id: \.self) { modelID in
                            Text(modelID).tag(modelID)
                        }
                    }
                    .disabled(model.isBusy)
                }

                Button {
                    Task {
                        await model.testModels(settings: settings)
                    }
                } label: {
                    if model.isTesting {
                        HStack {
                            ProgressView()
                            Text(model.testProgressText)
                        }
                    } else {
                        Label("Test Provider Models", symbol: .gaugeWithDotsNeedle50percent)
                    }
                }
                .disabled(model.isBusy || !model.hasStoredAPIKey)

                if !model.testResults.isEmpty {
                    ForEach(model.testResults) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.modelID)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            HStack {
                                Text("Score \(result.score)/\(result.maximumScore)")
                                Spacer()
                                Text(
                                    "\(result.averageElapsedSeconds, format: .number.precision(.fractionLength(2))) s/sample"
                                )
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(
                        "Keep Top \(model.topModelCount) Models",
                        value: $model.topModelCount,
                        in: 1...model.testResults.count
                    )

                    Button("Save Top \(model.topModelCount) Models") {
                        model.saveTopModels(settings: settings)
                    }
                    .disabled(model.isBusy)
                }

                if model.hasTestedModels {
                    Button("Restore Recommended Models") {
                        model.restoreRecommendedModels(settings: settings)
                    }
                    .disabled(model.isBusy)
                }

                if model.hasStoredAPIKey {
                    Button("Remove API Key", role: .destructive) {
                        isAPIKeyVisible = false
                        Task {
                            await model.removeAPIKey(settings: settings)
                        }
                    }
                    .disabled(model.isBusy)
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if let statusMessage = model.statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Voice Correction")
            } footer: {
                Text(
                    "Each provider starts with five built-in recommended models. Testing fetches "
                        + "the current provider's compatible models and sends the bundled voice samples "
                        + "for correction, which uses API credits. Save any Top N result as that provider's "
                        + "model list, or restore the recommendations at any time. API keys stay in this device’s Keychain. "
                        + "When configured, transcript candidates and recent terminal context are sent directly "
                        + "to the selected provider for correction; microphone audio is not uploaded."
                )
            }
            .task(id: scenePhase == .active ? settings.provider : nil) {
                if scenePhase == .active {
                    await model.prepare(settings: settings)
                }
            }
            .onChange(of: settings.provider) {
                isAPIKeyVisible = false
            }
            .onChange(of: scenePhase) {
                if scenePhase != .active {
                    isAPIKeyVisible = false
                }
            }
            .onDisappear {
                isAPIKeyVisible = false
            }
        }
    }
#endif
