#if os(macOS)
    import AppKit
    import CtrlxNetworking
    import Dependencies
    import SwiftUI
    import Testing
    @testable import CtrlxCommon

    @MainActor
    @Suite(.serialized)
    struct ViewerRelayAccessSettingsTests {
        @Test("Shared cards preserve failed Host rows and retry only verified members")
        func groupedCardsAndRetry() async throws {
            let probe = QuotaProbe()
            try await withDependencies {
                $0[RelayAccessClient.self] = RelayAccessClient(status: { server, pair, role in
                    #expect(server == "wss://relay.example.com" && role == "viewer")
                    return await probe.status(pair ?? "")
                }, removePair: { _, _, _ in
                    Issue.record("Unexpected pairing removal")
                }, validateKey: { _, _ in
                    Issue.record("Viewer must not request an account key")
                    throw URLError(.badURL)
                })
            } operation: {
                _ = NSApplication.shared
                NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
                var retried: [String] = []
                let hosts = ["a", "b", "c", "d"].map {
                    PairedHost(id: $0, hostName: "Host \($0.uppercased())", username: "fixture", partnerPublicKey: "", partnerPublicKeyId: "")
                }
                let view = Form {
                    ViewerRelayAccessSettingsSections(server: "wss://relay.example.com", hosts: hosts, restriction: { _ in nil }) {
                        retried.append($0)
                    }
                }
                .formStyle(.grouped)
                .environment(\.colorScheme, .dark)
                let hosting = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 700, height: 1_000), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = hosting
                window.orderBack(nil)
                defer { window.close() }

                let shared = try await waitFor("relay-quota-retry-shared", in: hosting)
                _ = try await waitFor("relay-quota-retry-other", in: hosting)
                let labels = nodes(in: hosting).flatMap { node in
                    ["accessibilityLabel", "accessibilityValue"].compactMap { attribute($0, from: node) as? String }
                }
                #expect(labels.contains { $0.contains("Host A, Host B") })
                #expect(labels.contains { $0.contains("Credential revoked for Host D") })
                if let directory = ProcessInfo.processInfo.environment["CTRLX_RELAY_UI_EVIDENCE"] {
                    hosting.layoutSubtreeIfNeeded()
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("viewer-account-cards.png"))
                }

                // One member is revoked while the card is open. A sibling's
                // successful quota response must not restore its permission.
                await probe.revokeB()
                let selector = NSSelectorFromString("accessibilityPerformPress")
                let implementation = try #require(shared.method(for: selector))
                #expect(unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(shared, selector))
                for _ in 0..<100 {
                    if !retried.isEmpty {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(retried == ["a"])
                #expect(await probe.readCounts() == ["a": 2, "b": 2, "c": 1, "d": 1])
            }
        }

        private func waitFor(_ identifier: String, in view: NSView) async throws -> NSObject {
            for _ in 0..<100 {
                if let node = nodes(in: view).first(where: { attribute("accessibilityIdentifier", from: $0) as? String == identifier }) {
                    return node
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw NSError(domain: "ViewerRelayAccessSettingsTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(identifier)"])
        }

        private func nodes(in root: NSView) -> [NSObject] {
            var queue: [Any] = [root], result: [NSObject] = []
            var visited: Set<ObjectIdentifier> = []
            while !queue.isEmpty {
                guard let node = queue.removeFirst() as? NSObject, visited.insert(ObjectIdentifier(node)).inserted else { continue }
                result.append(node)
                queue += attribute("accessibilityChildren", from: node) as? [Any] ?? []
                if let view = node as? NSView {
                    queue += view.subviews
                }
            }
            return result
        }

        private func attribute(_ name: String, from node: NSObject) -> Any? {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue()
        }
    }

    private actor QuotaProbe {
        private var counts: [String: Int] = [:]
        private var bRevoked = false
        func revokeB() {
            bRevoked = true
        }

        func readCounts() -> [String: Int] {
            counts
        }

        func status(_ pair: String) -> RelayAccessStatus {
            counts[pair, default: 0] += 1
            if pair == "d" || (pair == "b" && bRevoked) {
                return .init(metered: true, failure: .init(code: .authenticationRequired, message: "Credential revoked for Host \(pair.uppercased())"))
            }
            return .init(metered: true, quota: .init(
                accountID: pair == "c" ? "other" : "shared", accountName: pair == "c" ? "Work" : "personal", enabled: true,
                period: "2026-11", resetsAt: Date(timeIntervalSince1970: 1_796_054_400),
                baseBytes: 100 << 30, extraBytes: 0, usedBytes: 3 << 30, revision: 1
            ))
        }
    }
#endif
