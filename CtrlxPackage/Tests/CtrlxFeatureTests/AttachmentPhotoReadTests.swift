import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CtrlxFeature

@MainActor
struct AttachmentPhotoReadTests {
    private enum ReadError: Error { case missingData }

    @Test("An ordinary photo read delivers the provider's data")
    func ordinaryRead() async throws {
        let provider = NSItemProvider()
        let data = Data([1, 2, 3])
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        let result = try await AttachmentPhotoRead().load(provider, type: UTType.png.identifier, missingData: ReadError.missingData)
        #expect(result == data)
    }

    @Test("Cancelling a photo read cancels the provider and ignores a late result", .timeLimit(.minutes(1)))
    func cancellation() async throws {
        let provider = NSItemProvider()
        let progress = Progress(totalUnitCount: 1)
        let started = AsyncStream<Void>.makeStream()
        let delivered = AsyncStream<Void>.makeStream()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            started.continuation.yield()
            started.continuation.finish()
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                completion(Data([1, 2, 3]), nil)
                delivered.continuation.yield()
                delivered.continuation.finish()
            }
            return progress
        }

        let read = Task {
            try await AttachmentPhotoRead().load(provider, type: UTType.png.identifier, missingData: ReadError.missingData)
        }
        var start = started.stream.makeAsyncIterator()
        try #require(await start.next() != nil)
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(progress.isCancelled)
        var delivery = delivered.stream.makeAsyncIterator()
        try #require(await delivery.next() != nil)
    }
}
