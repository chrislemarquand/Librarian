// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Librarian",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/chrislemarquand/SharedUI.git", exact: "1.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "6.29.3"),
    ],
    targets: [
        .executableTarget(
            name: "Librarian",
            dependencies: [
                .product(name: "SharedUI", package: "SharedUI"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Librarian",
            exclude: [
                "Assets.xcassets",
                "AppIcon.icon",
                "Tools",
            ]
        ),
        .testTarget(
            name: "LibrarianTests",
            dependencies: ["Librarian"],
            path: "Tests/LibrarianTests"
        ),
    ]
)
