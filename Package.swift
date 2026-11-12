// swift-tools-version: 6.0
// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.

import PackageDescription

let package = Package(
    name: "DiscordAltyazi",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "DiscordAltyazi",
            path: "Sources/DiscordAltyazi",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
