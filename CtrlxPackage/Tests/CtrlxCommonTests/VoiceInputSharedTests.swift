import Dependencies
import Foundation
import Speech
import Testing
@testable import CtrlxCommon

@MainActor
@Suite("Shared voice configuration and ownership")
struct VoiceInputSharedTests {
    @Test("Original iOS preference keys survive the shared-store migration")
    func savedSettings() throws {
        let preferences = PreferencesService.inMemory()
        preferences.setString("volcengineArk", "voiceCorrectionProvider")
        preferences.setString("saved-model", "voiceCorrectionModelID")
        try preferences.setData(
            JSONEncoder().encode([VoiceCorrectionProvider.volcengineArk.rawValue: ["saved-model"]]),
            "voiceCorrectionTestedModelIDsByProvider"
        )
        withDependencies {
            $0[PreferencesService.self] = preferences
        } operation: {
            let settings = VoiceCorrectionSettings()
            #expect(settings.language == .system)
            #expect(!settings.debugModeEnabled)
            settings.debugModeEnabled = true
            settings.language = .simplifiedChinese
            #expect(VoiceCorrectionSettings().language == .simplifiedChinese)
            #expect(settings.provider == .volcengineArk)
            #expect(settings.selection?.modelID == "saved-model")
            #expect(settings.modelIDs(for: .volcengineArk) == ["saved-model"])
            settings.modelID = "new-model"
            settings.saveTestedModelIDs([" new-model ", "new-model", ""], for: .volcengineArk)
            let restored = VoiceCorrectionSettings()
            #expect(restored.debugModeEnabled)
            restored.debugModeEnabled = false
            #expect(!VoiceCorrectionSettings().debugModeEnabled)
            #expect(restored.modelID == "new-model")
            #expect(restored.modelIDs(for: .volcengineArk) == ["new-model"])
            restored.resetTestedModels(for: .volcengineArk)
            #expect(!VoiceCorrectionSettings().hasTestedModels(for: .volcengineArk))
        }
    }

    @Test("Unconfigured installations use built-in models without a provider selection")
    func defaults() {
        withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let settings = VoiceCorrectionSettings()
            #expect(settings.selection == nil)
            #expect(!settings.debugModeEnabled)
            #expect(settings.modelIDs(for: .volcengineArk) == VoiceCorrectionProvider.volcengineArk.recommendedModelIDs)
        }
    }

    @Test("Only one recording can own the microphone; stale cleanup cannot release another")
    func ownership() throws {
        let ownership = VoiceInputRecordingOwnership()
        let first = try #require(ownership.acquire())
        #expect(ownership.acquire() == nil)
        ownership.release(UUID())
        #expect(ownership.acquire() == nil)
        ownership.release(first)
        let second = try #require(ownership.acquire())
        ownership.release(first)
        #expect(ownership.acquire() == nil)
        ownership.release(second)
        #expect(ownership.acquire() != nil)
    }

    @Test("Permission failure releases ownership and publishes no completed input")
    func permissionDenied() async {
        let ownership = VoiceInputRecordingOwnership()
        await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[VoiceInputAuthorization.self] = .init(speech: { .denied }, microphone: {
                Issue.record("Microphone must not be requested after denied speech permission")
                return false
            })
        } operation: {
            let voice = VoiceInputController(ownership: ownership)
            voice.toggleRecording(context: .init(terminalText: "pane context"), correctionSelection: nil)
            for _ in 0..<200 {
                if voice.phase == .idle {
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(voice.phase == .idle)
            #expect(voice.errorMessage != nil)
            #expect(voice.completedTranscript == nil)
            #expect(ownership.acquire() != nil)
        }
    }

    @Test("Cancel during permission preparation blocks late permission results")
    func cancelPreparation() async {
        let gate = PermissionGate()
        let ownership = VoiceInputRecordingOwnership()
        await withDependencies {
            $0[PreferencesService.self] = .inMemory()
            $0[VoiceInputAuthorization.self] = .init(speech: { await gate.wait() }, microphone: {
                Issue.record("Cancelled preparation must not request microphone access")
                return false
            })
        } operation: {
            let voice = VoiceInputController(ownership: ownership)
            voice.toggleRecording(context: nil, correctionSelection: nil)
            await gate.waitUntilRequested()
            voice.cancel()
            await gate.resolve(.authorized)
            for _ in 0..<5 {
                await Task.yield()
            }
            #expect(voice.phase == .idle)
            #expect(voice.completedTranscript == nil)
            #expect(voice.errorMessage == nil)
            #expect(ownership.acquire() != nil)
        }
    }

    @Test("A second controller cannot start while the first is preparing")
    func multipleControllers() {
        withDependencies {
            $0[PreferencesService.self] = .inMemory()
        } operation: {
            let ownership = VoiceInputRecordingOwnership()
            let first = VoiceInputController(ownership: ownership)
            let second = VoiceInputController(ownership: ownership)
            first.toggleRecording(context: nil, correctionSelection: nil)
            second.toggleRecording(context: nil, correctionSelection: nil)
            #expect(second.phase == .idle)
            #expect(second.errorMessage != nil)
            first.cancel()
            second.cancel()
            #expect(ownership.acquire() != nil)
        }
    }

    private actor PermissionGate {
        private var permission: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>?
        private var requested: CheckedContinuation<Void, Never>?

        func wait() async -> SFSpeechRecognizerAuthorizationStatus {
            await withCheckedContinuation {
                permission = $0
                requested?.resume()
                requested = nil
            }
        }

        func waitUntilRequested() async {
            guard permission == nil else { return }
            await withCheckedContinuation { requested = $0 }
        }

        func resolve(_ status: SFSpeechRecognizerAuthorizationStatus) {
            permission?.resume(returning: status)
            permission = nil
        }
    }
}
