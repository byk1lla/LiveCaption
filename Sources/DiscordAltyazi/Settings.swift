// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.

import Foundation
import CoreGraphics

/// Kullanıcının seçebileceği çeviri arka ucu.
enum TranslatorBackend: String, CaseIterable {
    case claude
    case apple

    var displayName: String {
        switch self {
        case .claude: return "Claude CLI"
        case .apple:  return "Apple Çeviri"
        }
    }
}

/// Altyazı yazı boyutu kademeleri.
enum SubtitleFontSize: String, CaseIterable {
    case small, medium, large

    var displayName: String {
        switch self {
        case .small:  return "Küçük"
        case .medium: return "Orta"
        case .large:  return "Büyük"
        }
    }

    /// Türkçe altyazı punto değeri.
    var primary: CGFloat {
        switch self {
        case .small:  return 22
        case .medium: return 28
        case .large:  return 36
        }
    }

    /// Altındaki soluk İngilizce interim satırının puntosu.
    var secondary: CGFloat { primary * 0.58 }
}

/// Overlay bandının ekrandaki konumu.
enum OverlayPosition: String, CaseIterable {
    case bottom, top

    var displayName: String {
        switch self {
        case .bottom: return "Alt"
        case .top:    return "Üst"
        }
    }
}

/// UserDefaults üzerinde saklanan ayarlar.
@MainActor
final class Settings {
    static let shared = Settings()

    private enum Key {
        static let backend = "backend"
        static let fontSize = "fontSize"
        static let position = "position"
        static let overlayVisible = "overlayVisible"
        static let fastMode = "fastMode"
        static let sourceLanguage = "sourceLanguage"
        static let musicFilter = "musicFilter"
        static let fastRecognition = "fastRecognition"
        static let showSpeakerNames = "showSpeakerNames"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.backend: TranslatorBackend.claude.rawValue,
            Key.fontSize: SubtitleFontSize.medium.rawValue,
            Key.position: OverlayPosition.bottom.rawValue,
            Key.overlayVisible: true,
            Key.fastMode: true,
            Key.sourceLanguage: "en-US",
            Key.musicFilter: true,
            Key.fastRecognition: true,
            Key.showSpeakerNames: true
        ])
    }

    var backend: TranslatorBackend {
        get { TranslatorBackend(rawValue: defaults.string(forKey: Key.backend) ?? "") ?? .claude }
        set { defaults.set(newValue.rawValue, forKey: Key.backend) }
    }

    var fontSize: SubtitleFontSize {
        get { SubtitleFontSize(rawValue: defaults.string(forKey: Key.fontSize) ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: Key.fontSize) }
    }

    var position: OverlayPosition {
        get { OverlayPosition(rawValue: defaults.string(forKey: Key.position) ?? "") ?? .bottom }
        set { defaults.set(newValue.rawValue, forKey: Key.position) }
    }

    var overlayVisible: Bool {
        get { defaults.bool(forKey: Key.overlayVisible) }
        set { defaults.set(newValue, forKey: Key.overlayVisible) }
    }

    /// Konuşmanın kaynak dili (BCP-47, ör. "fr-FR").
    var sourceLanguage: String {
        get { defaults.string(forKey: Key.sourceLanguage) ?? "en-US" }
        set { defaults.set(newValue, forKey: Key.sourceLanguage) }
    }

    var sourceLocale: Locale { Locale(identifier: sourceLanguage) }

    /// Kaynak dilin ana kodu, ör. "fr".
    var sourceBaseCode: String { String(sourceLanguage.split(separator: "-").first ?? "en") }

    /// Türkçe görünen ad, ör. "Fransızca (Fransa)".
    var sourceDisplayName: String { LanguageCatalog.displayName(for: sourceLanguage) }

    /// Altyazıda konuşmacı adını göster (Discord'un arayüzünden okunur).
    var showSpeakerNames: Bool {
        get { defaults.bool(forKey: Key.showSpeakerNames) }
        set { defaults.set(newValue, forKey: Key.showSpeakerNames) }
    }

    /// Hızlı tanıma: SpeechTranscriber cümleyi daha erken kesinleştirir.
    /// Ölçüldü: gecikme belirgin düşüyor, doğruluk bir miktar azalıyor.
    var fastRecognition: Bool {
        get { defaults.bool(forKey: Key.fastRecognition) }
        set { defaults.set(newValue, forKey: Key.fastRecognition) }
    }

    /// Müzik/şarkı sözlerini çeviriye gönderme.
    var musicFilter: Bool {
        get { defaults.bool(forKey: Key.musicFilter) }
        set { defaults.set(newValue, forKey: Key.musicFilter) }
    }

    /// Hızlı mod: Apple çevirisi anında ekrana düşer, Claude gelince aynı
    /// satır düzeltilir. Altyazı ~1 sn erken görünür.
    var fastMode: Bool {
        get { defaults.bool(forKey: Key.fastMode) }
        set { defaults.set(newValue, forKey: Key.fastMode) }
    }
}
