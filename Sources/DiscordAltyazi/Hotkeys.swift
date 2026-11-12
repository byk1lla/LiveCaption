// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.

import AppKit
import Carbon.HIToolbox

/// Global kısayollar. Carbon'un RegisterEventHotKey'i kullanılıyor çünkü
/// NSEvent global monitor'ün aksine Erişilebilirlik izni istemiyor.
@MainActor
final class HotkeyManager {

    /// id -> aksiyon eşlemesi (C callback'ten erişilebilsin diye statik).
    nonisolated(unsafe) private static var actions: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var handlerInstalled = false

    private var registered: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1

    private static let signature: OSType = {
        // 'DCAZ'
        let chars: [UInt8] = Array("DCAZ".utf8)
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16) | (OSType(chars[2]) << 8) | OSType(chars[3])
    }()

    init() {
        installHandlerIfNeeded()
    }

    private func installHandlerIfNeeded() {
        guard !Self.handlerInstalled else { return }
        Self.handlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                HotkeyManager.actions[id]?()
            }
            return noErr
        }, 1, &eventType, nil, nil)
    }

    /// Kısayol kaydeder. `keyCode` Carbon sanal tuş kodu, `modifiers` cmdKey/shiftKey vb.
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        let id = nextID
        nextID += 1
        Self.actions[id] = action

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            registered.append(ref)
        } else {
            Log.warn(.app, "Kısayol kaydedilemedi (kod \(status))")
        }
    }

    /// Cmd+Shift+T ve Cmd+Shift+H kısayollarını kurar.
    func registerDefaults(toggleCapture: @escaping () -> Void, toggleOverlay: @escaping () -> Void) {
        register(keyCode: kVK_ANSI_T, modifiers: cmdKey | shiftKey, action: toggleCapture)
        register(keyCode: kVK_ANSI_H, modifiers: cmdKey | shiftKey, action: toggleOverlay)
        Log.info(.app, "Kısayollar hazır: ⌘⇧T yakalama, ⌘⇧H overlay")
    }

    func unregisterAll() {
        for ref in registered {
            if let ref { UnregisterEventHotKey(ref) }
        }
        registered.removeAll()
        Self.actions.removeAll()
    }
}
