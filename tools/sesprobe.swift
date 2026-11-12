// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.
//
// Kalibrasyon aracı. Discord'un erişilebilirlik ağacındaki sesli kanal
// bölümünü örnekler ve SADECE DEĞİŞENLERİ basar. Biri konuşmaya başlayıp
// bıraktığında hangi düğümün hangi niteliği değişiyor — konuşmacı tespitini
// buna göre yazacağız.
//
// Derle:  swiftc -O -o sesprobe sesprobe.swift
// Çalıştır: ./sesprobe          (20 sn, 0.4 sn aralıkla örnekler)
//           ./sesprobe 40       (40 sn)

import AppKit
import ApplicationServices

// MARK: - AX yardımcıları

func attr(_ el: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, key as CFString, &value) == .success ? value : nil
}

func attributeNames(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(el, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

/// Bir düğümün tüm okunabilir niteliklerini metne çevirir.
func snapshot(_ el: AXUIElement) -> String {
    var parts: [String] = []
    for name in attributeNames(el).sorted() {
        if ["AXChildren", "AXParent", "AXTopLevelUIElement", "AXWindow", "AXVisibleChildren"].contains(name) { continue }
        guard let raw = attr(el, name) else { continue }
        let text: String
        if let s = raw as? String { text = s }
        else if let n = raw as? NSNumber { text = n.stringValue }
        else if let b = raw as? Bool { text = b ? "true" : "false" }
        else if CFGetTypeID(raw) == AXValueGetTypeID() { continue }   // konum/boyut gürültüsü
        else { continue }
        if text.isEmpty { continue }
        parts.append("\(name)=\(text)")
    }
    return parts.joined(separator: " | ")
}

func describe(_ el: AXUIElement) -> String {
    let role = attr(el, kAXRoleAttribute) as? String ?? "?"
    let title = attr(el, kAXTitleAttribute) as? String ?? ""
    let desc = attr(el, kAXDescriptionAttribute) as? String ?? ""
    let value = attr(el, kAXValueAttribute) as? String ?? ""
    let text = [title, desc, value].filter { !$0.isEmpty }.joined(separator: " ¦ ")
    return "\(role)[\(text.prefix(60))]"
}

// MARK: - Discord'u aç

guard AXIsProcessTrusted() else {
    print("""
    ❌ Erişilebilirlik izni yok.
       Sistem Ayarları > Gizlilik ve Güvenlik > Erişilebilirlik
       → bu aracı çalıştırdığın uygulamaya (Terminal) izin ver.
    """)
    exit(1)
}

guard let discord = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.hnc.Discord" }) else {
    print("❌ Discord çalışmıyor.")
    exit(1)
}

let appElement = AXUIElementCreateApplication(discord.processIdentifier)
// Electron/Chromium web içerik ağacını açan anahtar — bu olmadan ağaç boş görünür.
AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
print("▸ AXManualAccessibility ayarlandı, ağacın açılması bekleniyor…")
Thread.sleep(forTimeInterval: 2.0)

// MARK: - İlgili bölgeyi bul

/// Sesli kanal panelini içeren düğümü arar. Bulamazsa tüm pencereyi gezer.
func findVoiceRegion(_ root: AXUIElement) -> (element: AXUIElement, label: String)? {
    var found: (AXUIElement, String)?
    func walk(_ el: AXUIElement, _ depth: Int) {
        if found != nil || depth > 26 { return }
        let title = attr(el, kAXTitleAttribute) as? String ?? ""
        let desc = attr(el, kAXDescriptionAttribute) as? String ?? ""
        let text = (title + " " + desc).lowercased()
        if text.contains("(ses kanalı)") || text.contains("(voice channel)")
            || text.contains("sesli sohbet") || text.contains("voice connected") {
            // Konuşan kişi bilgisi kardeş düğümlerde olabilir — bir üst seviyeye çık.
            if let parent = attr(el, kAXParentAttribute) as! AXUIElement?,
               let grandParent = attr(parent, kAXParentAttribute) as! AXUIElement? {
                found = (grandParent, [title, desc].filter { !$0.isEmpty }.joined(separator: " "))
            } else {
                found = (el, text)
            }
            return
        }
        if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for k in kids { walk(k, depth + 1) }
        }
    }
    walk(root, 0)
    return found
}

guard let windows = attr(appElement, kAXWindowsAttribute) as? [AXUIElement], let mainWindow = windows.first else {
    print("❌ Discord penceresi bulunamadı.")
    exit(1)
}

let forceFullWindow = CommandLine.arguments.contains("tam")
var region = mainWindow
var regionLabel = "tüm pencere"
if forceFullWindow {
    print("▸ Tüm pencere izlenecek (tam mod)")
} else if let hit = findVoiceRegion(mainWindow) {
    region = hit.element
    regionLabel = hit.label
    print("▸ Sesli kanal bölgesi bulundu: \(regionLabel)")
} else {
    print("⚠️  Sesli kanal düğümü bulunamadı — tüm pencere izlenecek (gürültülü olabilir).")
}

// MARK: - Örnekleme döngüsü

let duration = CommandLine.arguments.dropFirst().compactMap { Double($0) }.first ?? 20
let interval = 0.4

/// Yol -> nitelik dizesi
func collect(_ root: AXUIElement) -> [String: String] {
    var map: [String: String] = [:]
    func walk(_ el: AXUIElement, _ path: String, _ depth: Int) {
        if depth > 26 || map.count > 4000 { return }
        map[path] = snapshot(el)
        if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for (i, k) in kids.enumerated() {
                walk(k, "\(path).\(i)·\(describe(k))", depth + 1)
            }
        }
    }
    walk(root, "kök", 0)
    return map
}

print("""

▸ \(Int(duration)) saniye izleniyor, \(interval) sn aralıkla.
  ŞİMDİ sesli kanalda birinin konuşmasını sağla (sen konuşsan da olur).
  Konuş → sus → konuş, birkaç kez tekrarla.

""")

var previous = collect(region)
let startedAt = Date()
var changeCount = 0

while Date().timeIntervalSince(startedAt) < duration {
    Thread.sleep(forTimeInterval: interval)
    let current = collect(region)
    let stamp = String(format: "%5.1fs", Date().timeIntervalSince(startedAt))

    for (path, value) in current {
        guard let old = previous[path] else {
            changeCount += 1
            print("[\(stamp)] ➕ YENİ  \(path)\n          \(value)")
            continue
        }
        if old != value {
            changeCount += 1
            print("[\(stamp)] ✏️  DEĞİŞTİ \(path)")
            print("          ÖNCE: \(old)")
            print("          SONRA: \(value)")
        }
    }
    for path in previous.keys where current[path] == nil {
        changeCount += 1
        print("[\(stamp)] ➖ GİTTİ \(path)")
    }
    previous = current
}

print("\n▸ Bitti. \(changeCount) değişiklik yakalandı, \(previous.count) düğüm izlendi.")
if changeCount == 0 {
    print("""
      Hiç değişiklik yoksa: sesli kanalda kimse konuşmadı, ya da Discord
      konuşma durumunu erişilebilirlik ağacına yansıtmıyor. İkinci durumda
      yeşil halkayı ekran görüntüsünden okumaya geçeceğiz.
    """)
}
