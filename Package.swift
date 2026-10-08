// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Voidamp",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "Voidamp", targets: ["Voidamp"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [.executableTarget(
        name: "Voidamp",
        dependencies: [.product(name: "Sparkle", package: "Sparkle")],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    )],
    swiftLanguageModes: [.v5]
)
