// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Kalibrasyon: (1) sesli kanal düğüm yapısını konumlarıyla dök,
//              (2) Discord penceresini arkadayken yakalayıp PNG'ye yaz.
import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreImage

func attr(_ el: AXUIElement, _ k: String) -> CFTypeRef? {
    var v: CFTypeRef?; return AXUIElementCopyAttributeValue(el, k as CFString, &v) == .success ? v : nil
}
func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func text(_ el: AXUIElement) -> String {
    [attr(el, kAXTitleAttribute) as? String ?? "",
     attr(el, kAXDescriptionAttribute) as? String ?? "",
     attr(el, kAXValueAttribute) as? String ?? ""]
        .filter { !$0.isEmpty }.joined(separator: " ¦ ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

@main
struct Main {
    static func main() async {
        _ = NSApplication.shared   // CoreGraphics/pencere sunucusu bağlantısını başlat
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.hnc.Discord" })
        else { print("Discord yok ya da erişilebilirlik izni yok"); return }

        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(1500))

        guard let windows = attr(ax, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first,
              let windowFrame = axFrame(window) else { print("pencere yok"); return }
        print("Discord penceresi (AX): x=\(Int(windowFrame.minX)) y=\(Int(windowFrame.minY)) \(Int(windowFrame.width))x\(Int(windowFrame.height))")

        // ---- 1) Sesli kanal düğümünü bul, ALT AĞACINI konumlarıyla dök
        var voiceNode: AXUIElement?
        func find(_ el: AXUIElement, _ d: Int) {
            if voiceNode != nil || d > 28 { return }
            if text(el).lowercased().contains("(ses kanalı)") { voiceNode = el; return }
            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { find(k, d+1) } }
        }
        find(window, 0)

        guard let voice = voiceNode else { print("sesli kanal düğümü yok"); return }
        print("\n--- SESLİ KANAL ALT AĞACI (rol | metin | konum) ---")
        // Kanalın kendisi kenar çubuğundaki satır; üyeler KARDEŞ konteynerde olabilir.
        let container = (attr(voice, kAXParentAttribute).flatMap { $0 as! AXUIElement? })
            .flatMap { attr($0, kAXParentAttribute).flatMap { $0 as! AXUIElement? } } ?? voice
        func dump(_ el: AXUIElement, _ d: Int) {
            if d > 10 { return }
            let role = attr(el, kAXRoleAttribute) as? String ?? "?"
            let t = text(el)
            let f = axFrame(el)
            if !t.isEmpty || role == "AXImage" {
                let fs = f.map { "x=\(Int($0.minX)) y=\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "konum yok"
                print("\(String(repeating: "  ", count: d))\(role): \(t.prefix(70))   [\(fs)]")
            }
            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { dump(k, d+1) } }
        }
        dump(container, 0)

        // Üye satırları: sesli kanal düğümünün altındaki ~315x32 AXButton'lar
        var members: [(name: String, rect: CGRect)] = []
        func collectMembers(_ el: AXUIElement, _ d: Int) {
            if d > 10 { return }
            let role = attr(el, kAXRoleAttribute) as? String ?? ""
            if role == "AXButton", let f = axFrame(el), f.width > 250, f.height >= 24, f.height <= 48 {
                // AXTitle boş string dönebiliyor — o durumda da metne düş.
                let title = (attr(el, kAXTitleAttribute) as? String) ?? ""
                let source = title.isEmpty ? text(el) : title
                let name = source
                    .split(separator: "¦").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                if !name.isEmpty { members.append((name, f)) }
            }
            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { for k in kids { collectMembers(k, d+1) } }
        }
        collectMembers(container, 0)
        print("\n--- ÜYE SATIRLARI (\(members.count)):")
        for m in members { print("   \(m.name)  ->  x=\(Int(m.rect.minX)) y=\(Int(m.rect.minY)) \(Int(m.rect.width))x\(Int(m.rect.height))") }

        // ---- 2) Discord penceresini ARKADAYKEN yakala
        print("\n--- PENCERE YAKALAMA ---")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let discordWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == "com.hnc.Discord" }
            print("Discord pencereleri (\(discordWindows.count)):")
            for w in discordWindows {
                print("   \"\(w.title ?? "")\" \(Int(w.frame.width))x\(Int(w.frame.height)) onScreen=\(w.isOnScreen) id=\(w.windowID)")
            }
            // En büyük alanlı pencere ana penceredir.
            guard let scWindow = discordWindows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
            else { print("SCWindow bulunamadı"); return }
            print("Seçilen: \"\(scWindow.title ?? "")\" \(Int(scWindow.frame.width))x\(Int(scWindow.frame.height)) onScreen=\(scWindow.isOnScreen)")

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = Int(scWindow.frame.width * 2)
            config.height = Int(scWindow.frame.height * 2)
            config.showsCursor = false
            config.captureResolution = .best

            print("\n--- 12 SANİYE ÖRNEKLEME (0.6 sn aralık) ---")
            print("zaman   " + members.map { String($0.name.prefix(12)).padding(toLength: 13, withPad: " ", startingAt: 0) }.joined())
            let t0 = Date()
            var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            while Date().timeIntervalSince(t0) < 12 {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let scale0 = Double(image.width) / Double(scWindow.frame.width)
                var row = String(format: "%5.1fs  ", Date().timeIntervalSince(t0))
                if let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) {
                    let bpr = image.bytesPerRow, bpp = image.bitsPerPixel / 8
                    for m in members {
                        let lx = m.rect.minX - scWindow.frame.minX
                        let ly = m.rect.minY - scWindow.frame.minY
                        let box = CGRect(x: (lx + 2) * scale0, y: (ly - 1) * scale0, width: 38 * scale0, height: 38 * scale0)
                        var green = 0, total = 0
                        var y = Int(box.minY)
                        while y < Int(box.maxY) {
                            var x = Int(box.minX)
                            while x < Int(box.maxX) {
                                if x >= 0, y >= 0, x < image.width, y < image.height {
                                    let o = y * bpr + x * bpp
                                    let b = Int(ptr[o]), g = Int(ptr[o+1]), r = Int(ptr[o+2])
                                    total += 1
                                    if g > 90 && g > r * 3 / 2 && g > b * 7 / 5 { green += 1 }
                                }
                                x += 1
                            }
                            y += 1
                        }
                        let ratio = total > 0 ? Double(green) * 100 / Double(total) : 0
                        row += String(format: "%6.2f%%      ", ratio)
                    }
                }
                print(row)
                try? await Task.sleep(for: .milliseconds(600))
            }
            print("Yakalanan görüntü: \(image.width)x\(image.height)")

            // Boş/siyah mı diye ortalama parlaklık ölç
            let ci = CIImage(cgImage: image)
            let ctx = CIContext()
            var avg = [UInt8](repeating: 0, count: 4)
            if let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
               let out = f.outputImage {
                ctx.render(out, toBitmap: &avg, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            }
            print("Ortalama renk: R\(avg[0]) G\(avg[1]) B\(avg[2])  (hepsi 0 ise boş kare)")

            // ---- 3) Avatar çevresindeki yeşil halkayı ölç
            let scale = Double(image.width) / Double(scWindow.frame.width)
            print("\n--- HALKA ÖLÇÜMÜ (ölçek \(String(format: "%.1f", scale))x) ---")
            if let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) {
                let bpr = image.bytesPerRow
                let bpp = image.bitsPerPixel / 8
                for m in members {
                    // Satırın pencere içindeki yeri (AX ekran koordinatı - pencere köşesi)
                    let localX = m.rect.minX - scWindow.frame.minX
                    let localY = m.rect.minY - scWindow.frame.minY
                    // Avatar satırın solunda, ~24px; çevresinde 4px bant tara
                    let box = CGRect(x: (localX + 4) * scale, y: (localY + 1) * scale,
                                     width: 34 * scale, height: 34 * scale)
                    var green = 0, total = 0, maxG = 0
                    var y = Int(box.minY)
                    while y < Int(box.maxY) {
                        var x = Int(box.minX)
                        while x < Int(box.maxX) {
                            guard x >= 0, y >= 0, x < image.width, y < image.height else { x += 1; continue }
                            let o = y * bpr + x * bpp
                            let b = Int(ptr[o]), g = Int(ptr[o+1]), r = Int(ptr[o+2])
                            total += 1
                            maxG = max(maxG, g)
                            // Discord konuşma yeşili ≈ #23A55A (35,165,90)
                            if g > 100 && g > r * 3 / 2 && g > b * 7 / 5 { green += 1 }
                            x += 1
                        }
                        y += 1
                    }
                    let ratio = total > 0 ? Double(green) / Double(total) * 100 : 0
                    print(String(format: "   %-18@ yeşil piksel: %4d/%4d (%.1f%%)  enYüksekG=%3d", m.name as NSString, green, total, ratio, maxG))
                }
            } else {
                print("   piksel verisi okunamadı")
            }

            let out = URL(fileURLWithPath: "/tmp/discord-yakalama.png")
            if let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
                print("PNG yazıldı: \(out.path)")
            }
        } catch {
            print("Yakalama hatası: \(error.localizedDescription)")
        }
    }
}
