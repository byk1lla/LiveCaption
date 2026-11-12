// swift-tools-version: 6.0
// LiveCaption · © 2026 IEF Software · iefsoftware.tr
// MIT Lisansı — bkz. LICENSE.

import PackageDescription

let package = Package(
    name: "LiveCaption",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "LiveCaption",
            path: "Sources/LiveCaption",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
