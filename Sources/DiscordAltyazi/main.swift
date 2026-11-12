// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.

import AppKit

let application = NSApplication.shared
// Top-level kod nonisolated; AppDelegate @MainActor olduğu için ana iş
// parçacığında olduğumuzu açıkça belirtiyoruz.
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
// Dock'ta ikon yok, menü çubuğu uygulaması.
application.setActivationPolicy(.accessory)
application.run()
