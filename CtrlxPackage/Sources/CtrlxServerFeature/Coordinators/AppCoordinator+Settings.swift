import Foundation

extension AppCoordinator {
    func saveTmuxConfigurationForNextLaunch(_ draft: TmuxSettingsDraft) async throws -> TmuxSettingsDraft {
        let configuration = try await draft.validated()
        settings.saveTmuxConfigurationForNextLaunch(configuration)
        return configuration
    }
}
