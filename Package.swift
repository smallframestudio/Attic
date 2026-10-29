// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PSTArchiveReader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PSTArchiveReader", targets: ["PSTArchiveReader"]),
        .executable(name: "attic-pdftext", targets: ["AtticPDFText"]),
    ],
    targets: [
        // Everything that isn't UI: MIME parsing, the SQLite full-text index, and the importer.
        .target(
            name: "PSTCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The SwiftUI app.
        .executableTarget(
            name: "PSTArchiveReader",
            dependencies: ["PSTCore"]
        ),
        // Reads PDF text in its own process, so a PDF that hangs Apple's parser can be killed.
        .executableTarget(
            name: "AtticPDFText",
            path: "Sources/AtticPDFText"
        ),
        .testTarget(
            name: "PSTCoreTests",
            dependencies: ["PSTCore"]
        ),
    ]
)
