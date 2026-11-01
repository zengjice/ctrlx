# syntax=docker/dockerfile:1.4

# Generate the Linux-only lock file with:
#   scripts/update-server-package-lock.sh
# This stage deliberately receives no Apple Package.resolved, so conditional
# macOS dependencies never enter the Relay graph.
FROM swift:6.3-jammy AS server-lock-resolver

WORKDIR /lock
COPY Package.swift Package.server.resolved ./
RUN cp Package.server.resolved Package.resolved
COPY Sources/CSQLite ./Sources/CSQLite
RUN git config --global http.version HTTP/1.1
RUN mkdir -p Sources/CtrlxNetworking Sources/CtrlxExternalServer && \
    echo 'public struct Placeholder {}' > Sources/CtrlxNetworking/Placeholder.swift && \
    echo '@main struct Main { static func main() {} }' > Sources/CtrlxExternalServer/main.swift
RUN --mount=type=cache,id=ctrlx-relay-swiftpm,target=/lock/.build \
    swift package resolve && \
    mkdir -p /server-lock && \
    cp Package.resolved /server-lock/Package.server.resolved

FROM scratch AS server-lock
COPY --from=server-lock-resolver /server-lock/ /

# Build stage. Swift 6.3+ is required for swift-dependencies package traits.
FROM swift:6.3-jammy AS builder

WORKDIR /build
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev pkg-config && rm -rf /var/lib/apt/lists/*
RUN git config --global http.version HTTP/1.1

# Step 1: Copy ONLY the manifest and Linux Relay lock file.
COPY Package.swift Package.server.resolved ./
COPY Sources/CSQLite ./Sources/CSQLite
RUN cp Package.server.resolved Package.resolved

# Step 2: Create minimal directory structure for package resolution
# This allows swift package resolve to work without the actual source code
RUN mkdir -p Sources/CtrlxNetworking Sources/CtrlxExternalServer && \
    echo 'public struct Placeholder {}' > Sources/CtrlxNetworking/Placeholder.swift && \
    echo '@main struct Main { static func main() {} }' > Sources/CtrlxExternalServer/main.swift

# Step 3: Resolve and fetch dependencies (CACHED unless Package.swift/resolved changes)
RUN --mount=type=cache,id=ctrlx-relay-swiftpm,target=/build/.build \
    SWIFTPM_MAX_CONCURRENT_OPERATIONS=1 \
    swift package --skip-update --disable-automatic-resolution resolve

# Step 4: Copy the actual source code (changes here only invalidate build, not dependency fetch)
COPY Sources ./Sources

# Step 5: SwiftPM validates every manifest target even when building one product.
# Copying the small Tests tree keeps that validation correct for test targets with
# arbitrary names instead of trying to parse Package.swift with naming guesses.
COPY Tests ./Tests

# Step 6: Build release binary with BuildKit cache mount for incremental builds
# The cache mount persists .build across builds but isn't included in the layer,
# so we copy the binary to /tmp/ within the same RUN instruction
RUN --mount=type=cache,id=ctrlx-relay-swiftpm,target=/build/.build \
    swift build --jobs 1 -c release --product CtrlxExternalServer \
    -Xswiftc -cross-module-optimization && \
    cp .build/release/CtrlxExternalServer /tmp/

# Runtime stage - use slim image
FROM swift:6.3-jammy-slim

WORKDIR /app

# Install curl so the docker-compose healthcheck can call /health. The slim
# image otherwise lacks any HTTP client, so the healthcheck would always fail.
RUN apt-get update && apt-get install -y --no-install-recommends curl libsqlite3-0 && \
    rm -rf /var/lib/apt/lists/*

# Source metadata changes on every release. Declare it after OS dependencies so
# a new commit does not invalidate the expensive apt layer.
ARG CTRLX_VERSION=3.0.0
ARG CTRLX_SOURCE_REVISION=development
ARG CTRLX_SOURCE_REPOSITORY=https://github.com/jicezeng/CtrlX

# Copy the built binary (from /tmp/ where we placed it after build due to cache mount)
COPY --from=builder /tmp/CtrlxExternalServer ./

# Create non-root user for security
RUN useradd --create-home --shell /bin/bash appuser && \
    mkdir -p /data && \
    chown appuser:appuser /data
USER appuser

# Expose the default port
EXPOSE 8080

# Set environment
ENV ENVIRONMENT=production
ENV CTRLX_VERSION=$CTRLX_VERSION
ENV CTRLX_SOURCE_REVISION=$CTRLX_SOURCE_REVISION
ENV CTRLX_SOURCE_REPOSITORY=$CTRLX_SOURCE_REPOSITORY

LABEL org.opencontainers.image.title="CtrlX Relay"
LABEL org.opencontainers.image.source=$CTRLX_SOURCE_REPOSITORY
LABEL org.opencontainers.image.revision=$CTRLX_SOURCE_REVISION
LABEL org.opencontainers.image.version=$CTRLX_VERSION
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"

# Run the server
ENTRYPOINT ["./CtrlxExternalServer"]
