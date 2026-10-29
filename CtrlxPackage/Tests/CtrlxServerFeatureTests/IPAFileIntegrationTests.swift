#if os(macOS)
    import AppKit
    import CtrlxCommon
    import Dependencies
    import Testing
    @testable import CtrlxServerFeature

    @MainActor
    struct IPAFileIntegrationTests {
        private let other = IPAFileAssociation(applicationName: "iOS App Installer", isCtrlX: false)
        private let ctrlx = IPAFileAssociation(applicationName: "CtrlX", isCtrlX: true)

        @Test
        func openEventsRetainColdLaunchFilesAndAcceptLaterFiles() throws {
            let integration = IPAFileIntegration()
            let delegate = AppShutdownDelegate()
            delegate.onOpenFiles = { integration.receive($0) }
            let first = URL(fileURLWithPath: "/tmp/First.ipa")
            let second = URL(fileURLWithPath: "/tmp/Second.IPA")
            try delegate.application(NSApplication.shared, open: [first, first, #require(URL(string: "https://example.com/file.ipa")), URL(fileURLWithPath: "/tmp/file.zip")])
            #expect(integration.takeFiles() == [first])
            #expect(integration.takeFiles().isEmpty)
            delegate.application(NSApplication.shared, open: [second, first])
            #expect(integration.takeFiles() == [second, first])
        }

        @Test(arguments: [false, true], [false, true])
        func startupOnlySuggestsOnceAndNeverChangesAssociation(remind: Bool, alreadyDefault: Bool) {
            var reads = 0
            let result = alreadyDefault ? ctrlx : other
            withDependencies {
                $0[IPAFileAssociationClient.self] = .init(current: { reads += 1
                    return result
                }, setDefault: {
                    Issue.record("Startup must not change the system association")
                })
            } operation: {
                let integration = IPAFileIntegration()
                integration.checkDefaultApplication(remind: remind)
                #expect(integration.defaultApplicationPrompt == (remind && !alreadyDefault ? other : nil))
                integration.defaultApplicationPrompt = nil
                integration.checkDefaultApplication(remind: true)
                #expect(integration.defaultApplicationPrompt == nil)
                #expect(reads == (remind ? 1 : 0))
            }
        }

        @Test
        func successfulSettingReadsBackTheNewHandler() async throws {
            var changed = false
            let client = IPAFileAssociationClient(current: { changed ? ctrlx : other }, setDefault: { changed = true })
            #expect(try await client.setDefaultAndVerify() == ctrlx)
            #expect(changed)
        }

        @Test
        func failedOrDeclinedSystemChangeIsNotReportedAsSuccess() async {
            let unchanged = IPAFileAssociationClient(current: { other }, setDefault: { })
            await #expect(throws: IPAInstallationError.self) { try await unchanged.setDefaultAndVerify() }
            var reads = 0
            let declined = IPAFileAssociationClient(current: { reads += 1
                return ctrlx
            }, setDefault: {
                throw IPAInstallationError(message: "Declined")
            })
            await #expect(throws: IPAInstallationError.self) { try await declined.setDefaultAndVerify() }
            #expect(reads == 0)
        }

        @Test(arguments: [
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
            NSError(domain: NSOSStatusErrorDomain, code: -128),
        ])
        func systemCancellationIsNotASettingFailure(_ error: NSError) async {
            let client = IPAFileAssociationClient(current: {
                Issue.record("Cancelled changes must not be reported as verified")
                return ctrlx
            }, setDefault: { throw error })
            await #expect(throws: CancellationError.self) { try await client.setDefaultAndVerify() }
        }

        @Test
        func unrelatedErrorsKeepTheirOriginalDetails() async {
            let error = NSError(domain: "IPAFileAssociationTests", code: NSUserCancelledError)
            let client = IPAFileAssociationClient(current: { other }, setDefault: { throw error })
            do {
                _ = try await client.setDefaultAndVerify()
                Issue.record("The system failure must be reported")
            } catch let actual {
                #expect(actual as NSError == error)
            }
        }

        @Test
        func dismissedWaitIgnoresLateSystemCompletion() async throws {
            let started = AsyncStream<Void>.makeStream()
            var completion: CheckedContinuation<Void, Never>?
            var reads = 0
            let client = IPAFileAssociationClient(current: {
                reads += 1
                return ctrlx
            }, setDefault: {
                await withCheckedContinuation {
                    completion = $0
                    started.continuation.yield(())
                }
            })
            let request = Task { try await client.setDefaultAndVerify() }
            var iterator = started.stream.makeAsyncIterator()
            _ = await iterator.next()
            request.cancel()
            try #require(completion).resume()
            await #expect(throws: CancellationError.self) { try await request.value }
            #expect(reads == 0)
        }

        @Test
        func cancelledTaskDoesNotStartASettingRequest() async {
            let client = IPAFileAssociationClient(current: { other }, setDefault: {
                Issue.record("A cancelled task must not start the system request")
            })
            let request = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await client.setDefaultAndVerify()
            }
            await #expect(throws: CancellationError.self) { try await request.value }
        }

        @Test
        func reminderPreferencePersistsAndDefaultsToEnabled() {
            withDependencies { $0[PreferencesService.self] = .inMemory() } operation: {
                let first = AppSettings()
                #expect(first.askToHandleIPAFiles)
                first.askToHandleIPAFiles = false
                let next = AppSettings()
                #expect(!next.askToHandleIPAFiles)
                next.askToHandleIPAFiles = true
                #expect(AppSettings().askToHandleIPAFiles)
            }
        }
    }
#endif
