// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Attic",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Attic", targets: ["Attic"]),
        .executable(name: "attic-pdftext", targets: ["AtticPDFText"]),
    ],
    targets: [
        // Everything that isn't UI: MIME parsing, the SQLite full-text index, and the importer.
        .target(
            name: "AtticCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The SwiftUI app.
        .executableTarget(
            name: "Attic",
            dependencies: ["AtticCore"]
        ),
        // Reads PDF text in its own process, so a PDF that hangs Apple's parser can be killed.
        .executableTarget(
            name: "AtticPDFText",
            path: "Sources/AtticPDFText"
        ),
        .testTarget(
            name: "AtticCoreTests",
            dependencies: ["AtticCore"]
        ),
    ]
)
