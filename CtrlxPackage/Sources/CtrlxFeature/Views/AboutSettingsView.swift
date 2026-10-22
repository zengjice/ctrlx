#if os(iOS)
    import CtrlxCommon
    import SwiftUI

    struct AboutSettingsView: View {
        @Environment(IOSSettings.self) private var settings

        var body: some View {
            List {
                // About Section
                Section("About") {
                    LabeledContent("Version") {
                        Text(AppBuildInfo.current.displayVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Device ID") {
                        Text(settings.deviceId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Distribution provenance
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CtrlX is an independent distribution based on Gallager and licensed under GNU AGPL-3.0. It is not affiliated with or endorsed by the Gallager project.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Link(destination: AppBuildInfo.current.correspondingSourceURL) {
                        HStack {
                            Text("CtrlX Source")
                            Spacer()
                            Text("GitHub")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Link(destination: ProductIdentity.upstreamURL) {
                        HStack {
                            Text("Gallager Upstream")
                            Spacer()
                            Text("GitHub")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Origin and License")
                }

                // Licenses Section
                Section {
                    NavigationLink {
                        ThirdPartyLicensesView()
                    } label: {
                        Text("Licenses")
                    }
                }
            }
            .navigationTitle("About CtrlX")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
#endif
