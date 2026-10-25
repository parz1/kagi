// swift-tools-version: 6.0
import PackageDescription

// kagi 只依赖系统框架（CryptoKit、Security、LocalAuthentication、Foundation、AppKit），不引入任何第三方包。
let package = Package(
  name: "kagi",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "kagi", targets: ["kagi"])
  ],
  targets: [
    .target(name: "KagiCore"),
    .executableTarget(name: "kagi", dependencies: ["KagiCore"]),
    .testTarget(name: "KagiCoreTests", dependencies: ["KagiCore"]),
  ],
  swiftLanguageModes: [.v5]
)
