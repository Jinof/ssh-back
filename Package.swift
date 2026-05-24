// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ssh-back",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "SSHBackCore", targets: ["SSHBackCore"]),
    .executable(name: "ssh-back-menubar", targets: ["SSHBackMenuBar"])
  ],
  targets: [
    .target(name: "SSHBackCore"),
    .executableTarget(
      name: "SSHBackMenuBar",
      dependencies: ["SSHBackCore"]
    ),
    .testTarget(
      name: "SSHBackCoreTests",
      dependencies: ["SSHBackCore"]
    )
  ],
  swiftLanguageVersions: [.v5]
)
