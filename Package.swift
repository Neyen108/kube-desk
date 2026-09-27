// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "KubeDesk", platforms: [.macOS(.v13)], products: [.executable(name: "KubeDesk", targets: ["KubeDesk"])], targets: [.executableTarget(name: "KubeDesk"), .testTarget(name: "KubeDeskTests", dependencies: ["KubeDesk"])])
