// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DetectionEngine",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "DetectionEngine", targets: ["FallCore", "SelectedDetector", "MonitoringRuntime", "ModalTransport", "FallCaptureCore"])],
    targets: [
        .target(name: "FallCore"),
        .target(name: "SelectedDetector", dependencies: ["FallCore"], resources: [.process("Resources")]),
        .target(name: "MonitoringRuntime", dependencies: ["FallCore", "SelectedDetector"]),
        .target(name: "ModalTransport"),
        .target(name: "FallCaptureCore"),
        .testTarget(name: "SelectedDetectorTests", dependencies: ["FallCore", "SelectedDetector", "MonitoringRuntime", "ModalTransport", "FallCaptureCore"])
    ]
)
