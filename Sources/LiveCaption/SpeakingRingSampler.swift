// LiveCaption · © 2026 IEF Software · iefsoftware.tr
// MIT Lisansı — bkz. LICENSE.

import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

/// Discord'un sesli kanal panelindeki "konuşuyor" yeşil halkasını pikselden okur.
///
/// Neden piksel: Discord konuşma durumunu erişilebilirlik ağacına yansıtmıyor
/// (60 sn canlı sohbette ölçüldü, ağaçta yalnızca süre sayacı değişiyor).
/// Halka ise salt görsel ama ScreenCaptureKit pencereyi ARKADAYKEN de
/// yakalayabildiği için güvenilir şekilde okunabiliyor.
///
/// Maliyeti düşük tutmak için tüm pencere değil, sadece üye listesini kapsayan
/// küçük dikdörtgen yakalanıyor.
actor SpeakingRingSampler {

    /// Avatarın etrafında taranacak kutu, satırın soluna göre (nokta).
    private let avatarInset: CGFloat = 2
    private let avatarBox: CGFloat = 38

    /// Bu oranın üstü "konuşuyor" sayılır. Ölçüldü: konuşan %8.9, diğerleri %0.0–0.4.
    private let speakingThreshold = 2.0

    private var cachedWindow: SCWindow?
    private var lastWindowFetch = Date.distantPast

    /// Discord ana penceresini bulur (en büyük alanlı olan), 10 sn önbellekler.
    private func discordWindow() async -> SCWindow? {
        if let cachedWindow, Date().timeIntervalSince(lastWindowFetch) < 10 {
            return cachedWindow
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let windows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == "com.hnc.Discord"
            }
            let main = windows.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            cachedWindow = main
            lastWindowFetch = Date()
            return main
        } catch {
            Log.warn(.app, "Discord penceresi alınamadı: \(error.localizedDescription)")
            return nil
        }
    }

    func invalidate() {
        cachedWindow = nil
        lastWindowFetch = .distantPast
    }

    /// Verilen üye satırlarından hangisinin avatarında yeşil halka var?
    /// `rects` ekran koordinatında (AX) satır dikdörtgenleri.
    func speakingMember(_ members: [(name: String, rect: CGRect)]) async -> String? {
        guard !members.isEmpty, let window = await discordWindow() else { return nil }

        // Tüm satırları kapsayan bölge — pencereye göre yerel koordinat.
        var union = members[0].rect
        for member in members.dropFirst() { union = union.union(member.rect) }
        let region = CGRect(
            x: union.minX - window.frame.minX + avatarInset,
            y: union.minY - window.frame.minY - 1,
            width: avatarBox,
            height: union.height + 2
        ).integral

        guard region.width > 4, region.height > 4 else { return nil }

        let config = SCStreamConfiguration()
        config.sourceRect = region
        config.width = Int(region.width * 2)
        config.height = Int(region.height * 2)
        config.showsCursor = false
        config.captureResolution = .best

        let filter = SCContentFilter(desktopIndependentWindow: window)

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            // Pencere kapanmış/değişmiş olabilir.
            invalidate()
            return nil
        }

        guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return nil }
        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = image.bitsPerPixel / 8
        let scale = Double(image.width) / Double(region.width)

        var best: (name: String, ratio: Double)?
        for member in members {
            // Satırın, yakalanan bölgeye göre yeri.
            let localY = member.rect.minY - union.minY
            let box = CGRect(x: 0,
                             y: localY * scale,
                             width: Double(image.width),
                             height: avatarBox * scale)

            var green = 0
            var total = 0
            var y = Int(box.minY)
            let maxY = min(Int(box.maxY), image.height)
            while y < maxY {
                var x = 0
                while x < image.width {
                    let offset = y * bytesPerRow + x * bytesPerPixel
                    let b = Int(pointer[offset])
                    let g = Int(pointer[offset + 1])
                    let r = Int(pointer[offset + 2])
                    total += 1
                    // Discord konuşma yeşili ≈ #23A55A (35,165,90)
                    if g > 90, g > r * 3 / 2, g > b * 7 / 5 { green += 1 }
                    x += 1
                }
                y += 1
            }
            guard total > 0 else { continue }
            let ratio = Double(green) * 100 / Double(total)
            if ratio >= speakingThreshold, ratio > (best?.ratio ?? 0) {
                best = (member.name, ratio)
            }
        }
        return best?.name
    }
}
