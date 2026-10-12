// swift-tools-version: 6.2
import Foundation
import PackageDescription

guard let sdkPath = ProcessInfo.processInfo.environment["CTRLX_PEEKABOO_SDK_PATH"],
      !sdkPath.isEmpty
else {
    fatalError("Set CTRLX_PEEKABOO_SDK_PATH to the pinned Peekaboo source directory.")
}

let package = Package(
    name: "PeekabooSimulatorProbe",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "peekaboo-simulator-probe", targets: ["PeekabooSimulatorProbe"])],
    dependencies: [.package(name: "Peekaboo", path: sdkPath)],
    targets: [
        .executableTarget(
            name: "PeekabooSimulatorProbe",
            dependencies: [
                .product(name: "PeekabooAutomationKit", package: "Peekaboo"),
                .product(name: "PeekabooFoundation", package: "Peekaboo"),
            ]),
    ],
    swiftLanguageModes: [.v6])
