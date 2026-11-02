import CtrlxNetworking
import Foundation
import UniformTypeIdentifiers

#if os(iOS)
    import PhotosUI
    import SwiftUI
#endif

/// Providers stay on the UI actor; only their immutable bytes cross to decoding.
@MainActor
enum AgentWorkflowImageSource {
    case file(URL)
    case image(ClipboardImage)
    case provider(NSItemProvider)
    #if os(iOS)
        case photo(PhotosPickerItem)
    #endif

    static let contentTypes: [UTType] = [.image, .fileURL]

    static func providers(_ providers: [NSItemProvider]) -> [Self] {
        providers.filter { provider in
            contentTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }.map(provider)
    }

    func load() async throws -> AgentWorkflowImage {
        switch self {
        case let .file(url): return try await AgentWorkflowImage.read(url)
        case let .image(image): return try await AgentWorkflowImage.prepare(image.data, name: "Image")
        case let .provider(provider):
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let data = try await representation(provider, type: UTType.fileURL.identifier)
                guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                    throw AgentWorkflowError("Drop a local image file.")
                }
                return try await AgentWorkflowImage.read(url)
            }
            let candidates = [UTType.png.identifier, UTType.jpeg.identifier] + provider.registeredTypeIdentifiers
            guard
                let type = candidates.first(where: {
                    UTType($0)?.conforms(to: .image) == true && provider.hasItemConformingToTypeIdentifier($0)
                }) else {
                throw AgentWorkflowError("Only images can be attached. Reference other files by their workspace paths.")
            }
            let data = try await representation(provider, type: type)
            return try await AgentWorkflowImage.prepare(data, name: provider.suggestedName ?? "Image")
        #if os(iOS)
            case let .photo(item):
                guard let data = try await item.loadTransferable(type: Data.self) else { throw AgentWorkflowError("The selected photo could not be read.") }
                return try await AgentWorkflowImage.prepare(data, name: "Photo")
        #endif
        }
    }

    private func representation(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: AgentWorkflowError("The image could not be read."))
                }
            }
        }
    }
}
