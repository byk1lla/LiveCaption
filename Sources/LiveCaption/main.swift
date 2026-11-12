// LiveCaption · © 2026 IEF Software · iefsoftware.tr
// MIT Lisansı — bkz. LICENSE.

import AppKit

let application = NSApplication.shared
// Top-level kod nonisolated; AppDelegate @MainActor olduğu için ana iş
// parçacığında olduğumuzu açıkça belirtiyoruz.
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
// Dock'ta ikon yok, menü çubuğu uygulaması.
application.setActivationPolicy(.accessory)
application.run()
