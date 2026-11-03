import CtrlxExternalServerLib
import Foundation
import Vapor

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)

let loadedEnvironment = try RelayEnvironmentLoader.load(
    from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
)

let app = try await Application.make(env)

do {
    if let source = loadedEnvironment.source {
        app.logger.info("Loaded CtrlX Relay configuration from \(source.lastPathComponent)")
    }
    try await configure(app, env: loadedEnvironment.values)
    try await app.execute()
} catch {
    do {
        try await app.asyncShutdown()
    } catch let shutdownError {
        app.logger.error("Relay shutdown failed: \(shutdownError)")
    }
    throw error
}

try await app.asyncShutdown()
