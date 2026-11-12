// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.

import Foundation
import Speech
import Translation

/// Menüde listelenecek bir kaynak dil.
struct LanguageOption: Sendable, Equatable {
    /// BCP-47 kimliği, ör. "fr-FR".
    let identifier: String
    /// Türkçe görünen ad, ör. "Fransızca (Fransa)".
    let displayName: String
    /// Konuşma modeli bu Mac'e inmiş mi?
    let isInstalled: Bool
    /// Apple bu dilden Türkçeye çevirebiliyor mu? (false ise sadece Claude çevirir)
    let appleCanTranslate: Bool

    var locale: Locale { Locale(identifier: identifier) }

    /// Dilin ana kodu, ör. "fr-FR" -> "fr".
    var baseCode: String {
        String(identifier.split(separator: "-").first ?? "en")
    }
}

/// Bu Mac'te konuşma tanımanın desteklediği dilleri bulur.
enum LanguageCatalog {

    /// Menüde en üste çıkacak, Discord'da en çok karşılaşılan diller.
    private static let öncelikli = ["en", "es", "fr", "de", "it", "pt", "ru", "tr", "ar", "ja", "ko", "zh"]

    /// Türkçe ad üretir: "fr-FR" -> "Fransızca (Fransa)".
    static func displayName(for identifier: String) -> String {
        let turkish = Locale(identifier: "tr_TR")
        if let name = turkish.localizedString(forIdentifier: identifier), !name.isEmpty {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return identifier
    }

    /// Desteklenen dilleri, kurulu olma ve Apple çeviri durumuyla birlikte döndürür.
    /// Apple çeviri sorgusu yavaş olabildiği için istemediğinde atlanabilir.
    static func options(checkTranslation: Bool = true) async -> [LanguageOption] {
        let supported = await SpeechTranscriber.supportedLocales
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })

        var availability: LanguageAvailability?
        if checkTranslation { availability = LanguageAvailability() }
        let target = Locale.Language(identifier: "tr")

        var result: [LanguageOption] = []
        for locale in supported {
            let id = locale.identifier(.bcp47)
            let base = String(id.split(separator: "-").first ?? "")

            var canTranslate = true
            if let availability {
                let status = await availability.status(from: Locale.Language(identifier: base), to: target)
                canTranslate = status != .unsupported
            }

            result.append(LanguageOption(
                identifier: id,
                displayName: displayName(for: id),
                isInstalled: installed.contains(id),
                appleCanTranslate: canTranslate
            ))
        }

        // Önce yaygın diller, sonra alfabetik.
        return result.sorted { lhs, rhs in
            let li = öncelikli.firstIndex(of: String(lhs.identifier.split(separator: "-").first ?? "")) ?? Int.max
            let ri = öncelikli.firstIndex(of: String(rhs.identifier.split(separator: "-").first ?? "")) ?? Int.max
            if li != ri { return li < ri }
            return lhs.displayName.localizedCompare(rhs.displayName) == .orderedAscending
        }
    }
}
