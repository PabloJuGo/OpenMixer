// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenMixer",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "OpenMixer", targets: ["OpenMixer"])],
    targets: [
        .target(name: "MixerCore"),
        .executableTarget(name: "OpenMixer", dependencies: ["MixerCore"]),
        .executableTarget(name: "SelfCheck", dependencies: ["MixerCore"]),
    ]
)
