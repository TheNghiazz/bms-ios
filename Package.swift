// swift-tools-version:5.9
// BMSCore – phần lõi giải mã giao thức BMS, thuần Swift (không CoreBluetooth).
// Chạy được test trên Windows/Linux/macOS: swift test  |  swift run bmscore-check
import PackageDescription

let package = Package(
    name: "BMSCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "BMSCore", targets: ["BMSCore"]),
        .executable(name: "bmscore-check", targets: ["BMSCoreCheck"]),
    ],
    targets: [
        .target(
            name: "BMSCore",
            resources: [.process("Resources")]   // golden_vectors.json
        ),
        .testTarget(
            name: "BMSCoreTests",
            dependencies: ["BMSCore"]
        ),
        .executableTarget(
            name: "BMSCoreCheck",
            dependencies: ["BMSCore"]
        ),
    ]
)
