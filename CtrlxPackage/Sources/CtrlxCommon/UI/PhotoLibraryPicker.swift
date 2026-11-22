#if os(iOS) || os(macOS)
    import Photos
    import SwiftUI

    @MainActor
    package struct PhotoLibraryPicker: View {
        package let limit: Int
        package let add: @MainActor ([PhotoLibraryPhoto]) async throws -> Void
        @Environment(\.dismiss) private var dismiss
        @Environment(\.scenePhase) private var scenePhase
        @Binding private var isSubmitting: Bool
        @State private var access = PHAuthorizationStatus.notDetermined
        @State private var assets: PHFetchResult<PHAsset>?
        @State private var albums: [PHAssetCollection] = []
        @State private var album: PHAssetCollection?
        @State private var selection: [PhotoLibraryPhoto] = []
        @State private var preview: PhotoLibraryPhoto?
        @State private var pendingAdd: [PhotoLibraryPhoto]?
        @State private var error: String?

        private var adding: Bool {
            pendingAdd != nil
        }

        package init(limit: Int, isSubmitting: Binding<Bool> = .constant(false), add: @escaping @MainActor ([PhotoLibraryPhoto]) async throws -> Void) {
            self.limit = limit
            _isSubmitting = isSubmitting
            self.add = add
        }

        package var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Button(preview == nil ? "Cancel" : "Back") {
                        if preview == nil {
                            dismiss()
                        } else {
                            preview = nil
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                    Spacer()
                    if preview != nil {
                        Text("Photo Preview").font(.headline)
                    } else if assets != nil {
                        albumMenu
                    } else {
                        Text("Photo Library").font(.headline)
                    }
                    Spacer()
                    Button(selection.isEmpty ? "Add" : "Add (\(selection.count))") {
                        pendingAdd = selection
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty || adding)
                }
                .padding()
                Divider()
                ZStack {
                    library
                        .opacity(preview == nil ? 1 : 0)
                        .allowsHitTesting(preview == nil)
                        .accessibilityHidden(preview != nil)
                    if let preview {
                        VStack(spacing: 12) {
                            PhotoLibraryPreview(photo: preview).id(preview)
                            Button(isSelected(preview) ? "Deselect Photo" : "Select Photo") {
                                toggle(preview)
                            }
                            .disabled(!canToggle(preview))
                            .padding(.bottom, 12)
                        }
                        .background(.background)
                    }
                }
                if adding {
                    ProgressView("Adding Photos…").padding()
                } else if let error {
                    Text(error).foregroundStyle(.red).font(.callout).padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(macOS)
                .frame(minWidth: 520, idealWidth: 680, minHeight: 430, idealHeight: 580)
            #endif
                .interactiveDismissDisabled(isSubmitting)
                .task {
                    if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    }
                    if !Task.isCancelled {
                        refreshAccess()
                    }
                }
                .onChange(of: scenePhase) {
                    if scenePhase == .active {
                        refreshAccess()
                    }
                }
                .task(id: hasPhotoAccess) {
                    guard hasPhotoAccess else { return }
                    let library = PHPhotoLibrary.shared()
                    let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    let observer = PhotoLibraryChanges(continuation: continuation)
                    library.register(observer)
                    defer { library.unregisterChangeObserver(observer) }
                    refreshAccess()
                    for await _ in changes {
                        refreshAccess()
                    }
                }
                .task(id: pendingAdd) {
                    guard let pendingAdd else { return }
                    error = nil
                    do {
                        for photo in pendingAdd {
                            _ = try photo.currentAsset()
                        }
                        try await add(pendingAdd)
                        try Task.checkCancellation()
                        dismiss()
                    } catch is CancellationError {
                        self.pendingAdd = nil
                    } catch {
                        refreshAccess()
                        self.error = error.localizedDescription
                        self.pendingAdd = nil
                    }
                }
        }

        private var albumMenu: some View {
            Menu {
                Button("Recent Photos") { loadPhotos(in: nil) }
                ForEach(albums, id: \.localIdentifier) { collection in
                    Button(collection.localizedTitle ?? "Album") { loadPhotos(in: collection) }
                }
            } label: {
                Text(album?.localizedTitle ?? "Recent Photos").font(.headline)
            }
            .accessibilityLabel("Photo album")
            .disabled(adding)
        }

        @ViewBuilder private var library: some View {
            if let assets {
                if assets.firstObject != nil {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 94), spacing: 8)], spacing: 8) {
                            ForEach(0..<assets.count, id: \.self) { index in
                                let asset = assets.object(at: index)
                                cell(asset)
                                    .id(asset.localIdentifier)
                            }
                        }
                        .padding(12)
                    }
                    .id(album?.localIdentifier)
                    .disabled(adding)
                } else {
                    ContentUnavailableView("No Photos", symbol: .photo)
                }
            } else if access == .notDetermined {
                ProgressView("Opening Photo Library…")
            } else {
                ContentUnavailableView(
                    "Photo Library Access Required", symbol: .photo,
                    description: "Allow Photos access in Settings to browse and enlarge photos here."
                )
            }
        }

        private func cell(_ asset: PHAsset) -> some View {
            let photo = PhotoLibraryPhoto(asset: asset)
            return ZStack(alignment: .bottomTrailing) {
                Button {
                    preview = photo
                } label: {
                    GeometryReader { geometry in
                        PhotoLibraryThumbnail(asset: asset)
                            .id(photo)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .background(.quaternary)
                    .clipShape(.rect(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(asset.creationDate.map { "Preview photo from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Preview photo")
                Button {
                    toggle(photo)
                } label: {
                    Label(isSelected(photo) ? "Deselect photo" : "Select photo", symbol: isSelected(photo) ? .checkmarkCircleFill : .circle)
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .padding(9)
                        .foregroundStyle(isSelected(photo) ? Color.accentColor : .primary)
                        .background(.regularMaterial, in: .circle)
                }
                .buttonStyle(.plain)
                .padding(4)
                .disabled(!canToggle(photo))
            }
        }

        private var hasPhotoAccess: Bool {
            access == .authorized || access == .limited
        }

        private func refreshAccess() {
            access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard hasPhotoAccess else {
                assets = nil
                albums = []
                album = nil
                selection = []
                preview = nil
                return
            }
            let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            albums = (0..<result.count).map(result.object(at:))
            let albumID = album?.localIdentifier
            loadPhotos(in: albums.first { $0.localIdentifier == albumID })

            let identifiers = selection.map(\.id) + (preview.map { [$0.id] } ?? [])
            guard !identifiers.isEmpty else { return }
            let accessible = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            let currentPhotos = Set((0..<accessible.count).map { PhotoLibraryPhoto(asset: accessible.object(at: $0)) })
            let accessibleIDs = Set(currentPhotos.map(\.id))
            if selection.contains(where: { accessibleIDs.contains($0.id) && !currentPhotos.contains($0) }) {
                error = PhotoLibraryReadError.changed.localizedDescription
            }
            selection.removeAll { !currentPhotos.contains($0) }
            if let preview {
                self.preview = currentPhotos.first { $0.id == preview.id }
            }
        }

        private func loadPhotos(in album: PHAssetCollection?) {
            self.album = album
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if let album {
                options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
                assets = PHAsset.fetchAssets(in: album, options: options)
            } else {
                assets = PHAsset.fetchAssets(with: .image, options: options)
            }
        }

        private func isSelected(_ photo: PhotoLibraryPhoto) -> Bool {
            selection.contains { $0.id == photo.id }
        }

        private func canToggle(_ photo: PhotoLibraryPhoto) -> Bool {
            !adding && (isSelected(photo) || selection.count < limit)
        }

        private func toggle(_ photo: PhotoLibraryPhoto) {
            guard canToggle(photo) else { return }
            if let index = selection.firstIndex(where: { $0.id == photo.id }) {
                selection.remove(at: index)
            } else {
                selection.append(photo)
            }
        }
    }

    final private class PhotoLibraryChanges: NSObject, PHPhotoLibraryChangeObserver {
        private let continuation: AsyncStream<Void>.Continuation

        init(continuation: AsyncStream<Void>.Continuation) {
            self.continuation = continuation
        }

        func photoLibraryDidChange(_: PHChange) {
            continuation.yield(())
        }
    }
#endif
