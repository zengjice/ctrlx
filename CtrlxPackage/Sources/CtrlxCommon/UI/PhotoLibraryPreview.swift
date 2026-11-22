#if os(iOS) || os(macOS)
    import Photos
    import SwiftUI

    #if os(macOS)
        import AppKit

        typealias PhotoPreviewImage = NSImage
    #else
        import UIKit

        typealias PhotoPreviewImage = UIImage
    #endif

    @MainActor
    struct PhotoLibraryThumbnail: View {
        let asset: PHAsset
        @State private var image: PhotoPreviewImage?

        var body: some View {
            Group {
                if let image {
                    Image(photo: image).resizable().scaledToFill()
                } else {
                    Symbols.photo.image.foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
            .task {
                image = try? await loadPhotoImage(asset, pixels: 280, contentMode: .aspectFill)
            }
        }
    }

    @MainActor
    struct PhotoLibraryPreview: View {
        let photo: PhotoLibraryPhoto
        @State private var image: PhotoPreviewImage?
        @State private var failed = false

        var body: some View {
            Group {
                if let image {
                    ZoomablePhotoPreview(image: image)
                } else if failed {
                    ContentUnavailableView(
                        "Photo Unavailable", symbol: .photo,
                        description: "The photo could not be loaded. Check your connection and go back to try again."
                    )
                } else {
                    ProgressView("Loading Photo…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                do {
                    let asset = try photo.currentAsset()
                    image = try await loadPhotoImage(asset, pixels: 4_096, contentMode: .aspectFit)
                } catch is CancellationError {
                    return
                } catch {
                    failed = true
                }
            }
        }
    }

    @MainActor
    struct ZoomablePhotoPreview: View {
        let image: PhotoPreviewImage
        #if os(macOS)
            @State private var zoom: CGFloat = 1
            @GestureState private var magnification: CGFloat = 1
        #endif

        var body: some View {
            #if os(iOS)
                LocalImagePreview(photo: image)
            #else
                VStack(spacing: 8) {
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical]) {
                            let size = fittedSize(in: geometry.size)
                            let scale = clampedZoom(zoom * magnification)
                            Image(photo: image).resizable().interpolation(.high)
                                .frame(width: size.width * scale, height: size.height * scale)
                                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                                .accessibilityLabel("Image preview")
                                .onTapGesture(count: 2) { zoom = zoom == 1 ? 2 : 1 }
                        }
                        .simultaneousGesture(MagnifyGesture()
                            .updating($magnification) { value, state, _ in state = value.magnification }
                            .onEnded { zoom = clampedZoom(zoom * $0.magnification) })
                    }
                    HStack {
                        Button { zoom = clampedZoom(zoom / 1.5) } label: { Label("Zoom Out", symbol: .minus) }
                            .disabled(zoom <= 1)
                        Button("Fit") { zoom = 1 }
                        Button { zoom = clampedZoom(zoom * 1.5) } label: { Label("Zoom In", symbol: .plus) }
                            .disabled(zoom >= 6)
                    }
                    .padding(.bottom, 8)
                }
            #endif
        }

        #if os(macOS)
            private func fittedSize(in viewport: CGSize) -> CGSize {
                let size = image.size
                let fit = min(viewport.width / max(1, size.width), viewport.height / max(1, size.height))
                return .init(width: size.width * fit, height: size.height * fit)
            }

            private func clampedZoom(_ scale: CGFloat) -> CGFloat {
                min(6, max(1, scale))
            }
        #endif
    }

    private extension Image {
        init(photo: PhotoPreviewImage) {
            #if os(macOS)
                self.init(nsImage: photo)
            #else
                self.init(uiImage: photo)
            #endif
        }
    }

    @MainActor
    private func loadPhotoImage(_ asset: PHAsset, pixels: CGFloat, contentMode: PHImageContentMode) async throws -> PhotoPreviewImage {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        return try await PhotoLibraryImageRequest<PhotoPreviewImage>().read { manager, finish in
            manager.requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels), contentMode: contentMode, options: options) { image, info in
                guard info?[PHImageResultIsDegradedKey] as? Bool != true else { return }
                finish(image, info?[PHImageErrorKey] as? Error)
            }
        }
    }
#endif
