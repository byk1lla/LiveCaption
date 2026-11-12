// LiveCaption · © 2026 IEF Software · iefsoftware.tr
// MIT Lisansı — bkz. LICENSE.

import AppKit
import ApplicationServices

/// Sesli kanalda kimin konuştuğunu bulur.
///
/// İki kaynağı birleştirir:
///  • **Erişilebilirlik ağacı** — üye adları ve satırların ekran koordinatları.
///    Electron içeriği `AXManualAccessibility` ile açılıyor (ölçüldü: ağaç
///    2 düğümden 162 düğüme çıkıyor).
///  • **Piksel** — konuşma anını veren yeşil halka. Discord bunu erişilebilirlik
///    ağacına yansıtmıyor (60 sn canlı sohbette ölçüldü), ama ScreenCaptureKit
///    pencereyi arkadayken de yakalayabiliyor.
///
/// Kendi kullanıcın hariç tutulur: Discord kendi sesini geri çalmadığı için
/// senin konuşman yakaladığımız seste zaten yok.
@MainActor
final class SpeakerDetector {

    private(set) var roster: [String] = []
    private(set) var currentSpeaker: String?
    private(set) var problem: String?
    /// Her örneklemede o an konuşan (ya da nil) bildirilir.
    var onSample: ((String?) -> Void)?

    private let sampler = SpeakingRingSampler()

    private var discordElement: AXUIElement?
    private var discordPID: pid_t?
    private var pollTask: Task<Void, Never>?
    private var rosterLogged = false
    private var localUser: String?
    /// Alt paneldeki (kullanıcı ayarları) metinler — kendi adımızı bulmak için.
    private var localPanelTexts: Set<String> = []

    /// Sesli kanal düğümü önbelleği — her turda tüm ağacı gezmek pahalı.
    private var cachedVoiceNode: AXUIElement?
    private var missCount = 0

    /// Ad sonuna Discord'un eklediği durum ekleri.
    private static let nameSuffixes = [
        ", Susturuldu", ", Sağırlaştırıldı", ", Muted", ", Deafened",
        ", Sunucuda susturuldu", ", Server muted"
    ]

    // MARK: - Yaşam döngüsü

    func start() {
        guard pollTask == nil else { return }
        guard AXIsProcessTrusted() else {
            problem = "Konuşmacı adı için Sistem Ayarları > Gizlilik > Erişilebilirlik'ten izin ver"
            Log.warn(.app, "Erişilebilirlik izni yok — konuşmacı adı okunamayacak")
            return
        }
        problem = nil
        attachToDiscord()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        Log.info(.app, "Konuşmacı tespiti başladı")
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        roster = []
        currentSpeaker = nil
        rosterLogged = false
        cachedVoiceNode = nil
        Task { [sampler] in await sampler.invalidate() }
    }

    // MARK: - Discord'a bağlan

    private func attachToDiscord() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.hnc.Discord"
        }) else {
            discordElement = nil
            discordPID = nil
            return
        }
        guard app.processIdentifier != discordPID else { return }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        discordElement = element
        discordPID = app.processIdentifier
        cachedVoiceNode = nil
        localUser = nil
        localPanelTexts = []
        Task { [sampler] in await sampler.invalidate() }
        Log.info(.app, "Discord'a bağlandı (pid \(app.processIdentifier)), erişilebilirlik ağacı açıldı")
    }

    // MARK: - Tur

    private func poll() async {
        if discordElement == nil { attachToDiscord() }
        guard let root = discordElement else {
            reset()
            return
        }
        if let pid = discordPID,
           NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) == nil {
            discordElement = nil
            discordPID = nil
            reset()
            return
        }

        guard let windows = Self.attribute(root, kAXWindowsAttribute) as? [AXUIElement],
              let window = windows.first else { reset(); return }

        // Sesli kanal düğümünü bul (önbellekli).
        if cachedVoiceNode == nil {
            cachedVoiceNode = findVoiceNode(in: window)
            if cachedVoiceNode == nil {
                reset()
                return
            }
        }
        guard let voiceNode = cachedVoiceNode else { reset(); return }

        if localPanelTexts.isEmpty { localPanelTexts = collectLocalPanelTexts(in: window) }

        var members: [(name: String, rect: CGRect)] = []
        collectMembers(voiceNode, depth: 0, into: &members)

        if members.isEmpty {
            missCount += 1
            if missCount >= 3 { cachedVoiceNode = nil; missCount = 0 }
            reset()
            return
        }
        missCount = 0

        roster = members.map(\.name)
        // Kendi adımız: alt paneldeki metinlerle kesişen üye.
        if localUser == nil {
            localUser = members.first { localPanelTexts.contains($0.name) }?.name
        }
        if !rosterLogged {
            rosterLogged = true
            let local = localUser.map { " (sen: \($0))" } ?? ""
            Log.info(.app, "Sesli kanaldakiler: \(roster.joined(separator: ", "))\(local)")
        }

        // Kendi sesimiz yakalanan seste yok — etiketlemede hariç tut.
        let others = members.filter { $0.name != localUser }

        var speaker = await sampler.speakingMember(others.isEmpty ? members : others)
        if speaker == nil, others.count == 1 {
            // Karşıda tek kişi varsa halka okunamasa da konuşan odur.
            speaker = others[0].name
        }
        if speaker == localUser { speaker = nil }

        if speaker != currentSpeaker, let speaker {
            Log.info(.app, "Konuşuyor: \(speaker)")
        }
        currentSpeaker = speaker
        onSample?(speaker)
    }

    private func reset() {
        roster = []
        currentSpeaker = nil
        rosterLogged = false
        onSample?(nil)
    }

    // MARK: - Ağaç okuma

    /// Kenar çubuğundaki sesli kanal bölümü.
    ///
    /// "(ses kanalı)" metni birden çok düğümde geçiyor: hem kanal adı butonunda
    /// hem de üyeleri kapsayan dış bağlantıda. Derinlik öncelikli arama içteki
    /// butonu önce bulabildiği ve onun altında üye satırı olmadığı için,
    /// eşleşmenin iki üstüne çıkıp üyeleri kapsayan konteyneri döndürüyoruz.
    private func findVoiceNode(in root: AXUIElement) -> AXUIElement? {
        var match: AXUIElement?
        func walk(_ element: AXUIElement, _ depth: Int) {
            if match != nil || depth > 28 { return }
            let text = Self.text(of: element).lowercased()
            if text.contains("(ses kanalı)") || text.contains("(voice channel)") {
                match = element
                return
            }
            if let kids = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                for kid in kids { walk(kid, depth + 1) }
            }
        }
        walk(root, 0)
        guard let match else { return nil }

        let parent = Self.attribute(match, kAXParentAttribute).flatMap { $0 as! AXUIElement? }
        let grandParent = parent.flatMap { Self.attribute($0, kAXParentAttribute) }
            .flatMap { $0 as! AXUIElement? }
        return grandParent ?? parent ?? match
    }

    /// Alt paneldeki (kullanıcı adı, durum, ping) metinleri toplar.
    /// Kendi adımızı doğrudan seçmek yerine, üye listesiyle kesiştirerek buluyoruz:
    /// panelde "164 ms" gibi kullanıcı adı olmayan metinler de var.
    private func collectLocalPanelTexts(in root: AXUIElement) -> Set<String> {
        var texts: Set<String> = []
        var found = false

        func dig(_ element: AXUIElement, _ depth: Int) {
            if depth > 8 { return }
            let text = Self.text(of: element)
                .split(separator: "¦").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            if !text.isEmpty, text.count <= 40 { texts.insert(text) }
            if let kids = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                for kid in kids { dig(kid, depth + 1) }
            }
        }

        func walk(_ element: AXUIElement, _ depth: Int) {
            if found || depth > 28 { return }
            let text = Self.text(of: element)
            if text.contains("Kullanıcı Durumu ve Ayarlar") || text.contains("User Status and Settings") {
                found = true
                dig(element, 0)
                return
            }
            if let kids = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                for kid in kids { walk(kid, depth + 1) }
            }
        }
        walk(root, 0)
        return texts
    }

    /// Üye satırları: sesli kanal düğümü altındaki geniş AXButton'lar (ölçüldü: 315x32).
    private func collectMembers(_ element: AXUIElement, depth: Int, into members: inout [(name: String, rect: CGRect)]) {
        if depth > 10 { return }
        if (Self.attribute(element, kAXRoleAttribute) as? String) == "AXButton",
           let frame = Self.frame(of: element),
           frame.width > 250, frame.height >= 24, frame.height <= 48 {
            let name = Self.cleanName(Self.text(of: element))
            if !name.isEmpty { members.append((name, frame)) }
        }
        if let kids = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for kid in kids { collectMembers(kid, depth: depth + 1, into: &members) }
        }
    }

    /// "kullanici, Susturuldu ¦ kullanici" -> "kullanici"
    private static func cleanName(_ raw: String) -> String {
        var name = raw.split(separator: "¦").first.map(String.init) ?? raw
        for suffix in nameSuffixes where name.contains(suffix) {
            name = name.replacingOccurrences(of: suffix, with: "")
        }
        if let comma = name.firstIndex(of: ",") { name = String(name[name.startIndex..<comma]) }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AX yardımcıları

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private static func text(of element: AXUIElement) -> String {
        // AXTitle boş string dönebiliyor; o durumda açıklama/değere düşülür.
        let title = (attribute(element, kAXTitleAttribute) as? String) ?? ""
        let description = (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
        let value = (attribute(element, kAXValueAttribute) as? String) ?? ""
        return [title, description, value]
            .filter { !$0.isEmpty }
            .joined(separator: " ¦ ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}

/// Konuşmacı geçmişini tutar: bir cümle kesinleştiğinde o aralıkta en çok
/// konuşan kişiyi döndürür.
@MainActor
final class SpeakerTracker {

    private var samples: [(time: Date, name: String)] = []
    private let lookback: TimeInterval = 3.5

    func record(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        samples.append((Date(), name))
        if samples.count > 200 { samples.removeFirst(samples.count - 200) }
    }

    func dominantSpeaker() -> String? {
        let cutoff = Date().addingTimeInterval(-lookback)
        samples.removeAll { $0.time < cutoff }
        guard !samples.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for sample in samples { counts[sample.name, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }

    func clear() { samples.removeAll() }
}
