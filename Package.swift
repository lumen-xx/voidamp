// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voidamp",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "Voidamp", targets: ["Voidamp"])],
    targets: [.executableTarget(name: "Voidamp")],
    swiftLanguageModes: [.v5]
)
