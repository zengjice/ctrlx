import CtrlxExternalServerLib
import Foundation
import Vapor

let loadedEnvironment = try RelayEnvironmentLoader.load(
    from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
)

if CommandLine.arguments.dropFirst().first == "relay-admin" {
    try print(await RelayAdmin.run(arguments: Array(CommandLine.arguments.dropFirst(2)), environment: loadedEnvironment.values))
} else {
    var env = try Environment.detect()
    try LoggingSystem.bootstrap(from: &env)
    let app = try await Application.make(env)
    do {
        if let source = loadedEnvironment.source {
            app.logger.info("Loaded CtrlX Relay configuration from \(source.lastPathComponent)")
        }
        try await configure(app, env: loadedEnvironment.values)
        try await app.execute()
        try await app.asyncShutdown()
    } catch {
        try await app.asyncShutdown()
        throw error
    }
}
