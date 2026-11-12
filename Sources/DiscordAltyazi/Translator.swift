// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.

import Foundation

/// Bir çeviri arka ucunun hazır olma durumu — menüde gösterilir.
enum BackendReadiness: Equatable {
    case idle            // henüz başlatılmadı
    case warming         // ısınıyor
    case ready           // hazır
    case cooldown        // art arda hata sonrası geçici devre dışı
    case unavailable(String)

    var label: String {
        switch self {
        case .idle: return "beklemede"
        case .warming: return "ısınıyor…"
        case .ready: return "hazır"
        case .cooldown: return "devre dışı"
        case .unavailable(let reason): return reason
        }
    }
}

/// Tüm çeviri arka uçlarının ortak arayüzü.
protocol Translator: AnyObject, Sendable {
    /// Loglarda ve menüde görünen kısa ad.
    var name: String { get }
    /// Şu anki hazırlık durumu.
    var readiness: BackendReadiness { get async }
    /// Arka ucu ayağa kaldır (ön ısıtma dahil).
    func prepare() async
    /// Tek bir cümleyi çevir. `context` son final cümleler (eskiden yeniye).
    func translate(_ text: String, context: [String]) async throws -> String
    /// Kaynakları temiz kapat.
    func shutdown() async
}

/// Zaman aşımı hatası.
struct TranslationTimeout: LocalizedError {
    let seconds: Double
    var errorDescription: String? { "Çeviri \(String(format: "%.0f", seconds)) sn içinde dönmedi." }
}

/// Verilen işi süre sınırıyla çalıştırır.
func withTimeout<T: Sendable>(_ seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TranslationTimeout(seconds: seconds)
        }
        guard let result = try await group.next() else {
            throw TranslationTimeout(seconds: seconds)
        }
        group.cancelAll()
        return result
    }
}

/// Önce tercih edilen arka ucu dener, olmazsa yedeğe düşer.
/// Art arda 3 hatada tercih edilen arka ucu 60 sn devre dışı bırakır.
actor FallbackTranslator {

    struct Result: Sendable {
        let text: String
        let backendName: String
        let fellBack: Bool
    }

    private let claude: ClaudeCLITranslator
    private let apple: AppleTranslator

    private var preferred: TranslatorBackend = .claude
    private var consecutiveFailures = 0
    private var disabledUntil: Date?

    /// Claude'a tanınan süre sınırı.
    private let claudeTimeout: Double = 3.0
    /// Art arda hata eşiği.
    private let failureThreshold = 3
    /// Devre dışı bırakma süresi.
    private let cooldownSeconds: Double = 60

    /// Durum değişince menü güncellensin diye.
    private var statusObserver: (@Sendable (TranslatorBackend, BackendReadiness) async -> Void)?

    init(claude: ClaudeCLITranslator, apple: AppleTranslator) {
        self.claude = claude
        self.apple = apple
    }

    func setStatusObserver(_ observer: @escaping @Sendable (TranslatorBackend, BackendReadiness) async -> Void) {
        self.statusObserver = observer
        // self'i hiç yakalamıyoruz: gözlemciyi doğrudan Claude'a bağlıyoruz,
        // böylece döngüsel referans da olmuyor.
        Task { [claude] in
            await claude.setStatusObserver { readiness in
                await observer(.claude, readiness)
            }
        }
    }

    private func notify(_ backend: TranslatorBackend, _ readiness: BackendReadiness) async {
        await statusObserver?(backend, readiness)
    }

    func setPreferred(_ backend: TranslatorBackend) async {
        guard preferred != backend else { return }
        preferred = backend
        consecutiveFailures = 0
        disabledUntil = nil
        Log.info(.translate, "Arka uç değişti: \(backend.displayName)")
        if backend == .claude {
            // Menüden Claude tekrar seçilirse aynı ısınma akışı çalışsın.
            await claude.prepare()
        } else {
            await apple.prepare()
        }
    }

    func currentPreferred() -> TranslatorBackend { preferred }

    /// Yakalama açıkken Apple oturumunu sıcak tut.
    func setKeepWarm(_ on: Bool) async {
        await apple.setKeepWarm(on)
    }

    /// Kaynak dil değişti: Claude süreçlerini yeni promptla kur, Apple oturumunu yenile.
    func setSourceLanguage(_ name: String) async {
        consecutiveFailures = 0
        disabledUntil = nil
        await apple.reconfigure()
        await claude.setSourceLanguage(name)
    }

    /// Menüde gösterilecek etkin arka uç tanımı.
    func activeDescription() async -> String {
        switch preferred {
        case .apple:
            return "Apple"
        case .claude:
            if let until = disabledUntil, until > Date() {
                let kalan = Int(until.timeIntervalSinceNow.rounded(.up))
                return "Apple (Claude \(kalan) sn devre dışı)"
            }
            let readiness = await claude.readiness
            switch readiness {
            case .ready: return "Claude (hazır)"
            case .warming: return "Claude (ısınıyor…)"
            case .idle: return "Claude (beklemede)"
            case .cooldown: return "Apple (Claude devre dışı)"
            case .unavailable(let reason): return "Apple (Claude yok: \(reason))"
            }
        }
    }

    /// Hızlı mod şu an uygulanabilir mi? (Claude seçili + ayar açık + Apple hazır)
    func fastModeActive() async -> Bool {
        guard preferred == .claude else { return false }
        guard await MainActor.run(body: { Settings.shared.fastMode }) else { return false }
        if let until = disabledUntil, until > Date() { return false }
        return await apple.readiness == .ready
    }

    /// Sadece Apple ile, anında çeviri. Başarısızsa nil.
    func translateFast(_ text: String) async -> Result? {
        guard await apple.readiness == .ready else { return nil }
        do {
            let translated = try await apple.translate(text, context: [])
            return Result(text: translated, backendName: "Apple", fellBack: false)
        } catch {
            Log.warn(.apple, "Hızlı yol çevirisi başarısız: \(error.localizedDescription)")
            return nil
        }
    }

    func prepare() async {
        if preferred == .claude {
            await claude.prepare()
        }
        // Apple her zaman yedek olduğu için arka planda hazırlanır.
        await apple.prepare()
    }

    func shutdown() async {
        await claude.shutdown()
        await apple.shutdown()
    }

    /// Asıl çeviri. Hata fırlatmaz — en kötü ihtimalde orijinal metni döndürür.
    func translate(_ text: String, context: [String]) async -> Result {
        if preferred == .apple {
            return await translateWithApple(text, fellBack: false)
        }

        // Claude devre dışı mı?
        if let until = disabledUntil {
            if until > Date() {
                return await translateWithApple(text, fellBack: true)
            }
            disabledUntil = nil
            consecutiveFailures = 0
            Log.info(.claude, "Devre dışı süresi doldu, Claude tekrar denenecek")
        }

        // Henüz ısınmadıysa bekleme — Apple'a düş.
        let readiness = await claude.readiness
        guard readiness == .ready else {
            Log.info(.translate, "Claude hazır değil (\(readiness.label)) — bu cümle Apple'a gidiyor")
            return await translateWithApple(text, fellBack: true)
        }

        do {
            let translated = try await withTimeout(claudeTimeout) { [claude] in
                try await claude.translate(text, context: context)
            }
            consecutiveFailures = 0
            return Result(text: translated, backendName: "Claude", fellBack: false)
        } catch {
            consecutiveFailures += 1
            Log.warn(.claude, "Çeviri hatası (\(consecutiveFailures)/\(failureThreshold)): \(error.localizedDescription)")
            if consecutiveFailures >= failureThreshold {
                disabledUntil = Date().addingTimeInterval(cooldownSeconds)
                Log.warn(.claude, "Art arda \(failureThreshold) hata — Claude \(Int(cooldownSeconds)) sn devre dışı")
                await notify(.claude, .cooldown)
            }
            return await translateWithApple(text, fellBack: true)
        }
    }

    private func translateWithApple(_ text: String, fellBack: Bool) async -> Result {
        do {
            let translated = try await apple.translate(text, context: [])
            return Result(text: translated, backendName: "Apple", fellBack: fellBack)
        } catch {
            Log.error(.apple, "Apple çevirisi de başarısız: \(error.localizedDescription)")
            // Hiçbir şey çevrilemiyorsa orijinali göster — uygulama çökmesin.
            return Result(text: text, backendName: "ham", fellBack: true)
        }
    }
}

/// Final cümleleri iki hatta işler:
///  • hızlı hat (Apple, yerel): cümle gelir gelmez ekrana basar
///  • kaliteli hat (Claude): aynı satırı birkaç yüz ms sonra düzeltir
/// Her hat kendi içinde sıralıdır, böylece satırlar hep doğru sırada görünür.
/// Hızlı mod kapalıysa yalnızca kaliteli hat çalışır (eski davranış).
actor TranslationPipeline {

    private let fallback: FallbackTranslator
    private var history: [String] = []       // son final kaynak cümleler (Claude bağlamı)

    private var fastQueue: [(id: UInt64, text: String, speaker: String?)] = []
    private var qualityQueue: [(id: UInt64, text: String, speaker: String?)] = []
    private var fastRunning = false
    private var qualityRunning = false

    /// Hızlı hat tarafından zaten ekrana basılmış satırlar.
    private var emitted: Set<UInt64> = []
    private var nextID: UInt64 = 0

    /// Yeni satır ekle (id, çeviri, konuşmacı, backend, ms).
    private let onLine: @Sendable (UInt64, String, String?, String, Int) async -> Void
    /// Var olan satırı düzelt.
    private let onRefine: @Sendable (UInt64, String, String, Int) async -> Void
    /// Kısa uyarı.
    private let onNotice: @Sendable (String) async -> Void

    private let maxContext = 3

    init(fallback: FallbackTranslator,
         onLine: @escaping @Sendable (UInt64, String, String?, String, Int) async -> Void,
         onRefine: @escaping @Sendable (UInt64, String, String, Int) async -> Void,
         onNotice: @escaping @Sendable (String) async -> Void) {
        self.fallback = fallback
        self.onLine = onLine
        self.onRefine = onRefine
        self.onNotice = onNotice
    }

    /// Çeviriye değmeyecek kadar kısa/anlamsız mı?
    private static let fillers: Set<String> = [
        "uh", "uhh", "um", "umm", "yeah", "yea", "yep", "nope", "hmm", "hm",
        "ah", "oh", "eh", "mhm", "huh", "okay", "ok", "so", "like", "right",
        "you know", "i mean", "well"
    ]

    private func isTrivial(_ text: String) -> Bool {
        let cleaned = text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted.subtracting(.whitespaces))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count < 3 { return true }
        let words = cleaned.split(separator: " ").map(String.init)
        if words.count <= 2 && words.allSatisfy({ Self.fillers.contains($0) }) { return true }
        if Self.fillers.contains(cleaned) { return true }
        return false
    }

    func enqueue(_ text: String, speaker: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isTrivial(trimmed) {
            Log.info(.translate, "Atlandı (çok kısa/dolgu): \(trimmed)")
            return
        }

        let id = nextID
        nextID += 1

        Task { [weak self] in
            guard let self else { return }
            let fast = await self.fallback.fastModeActive()
            await self.schedule(id: id, text: trimmed, speaker: speaker, useFastPath: fast)
        }
    }

    private func schedule(id: UInt64, text: String, speaker: String?, useFastPath: Bool) {
        if useFastPath {
            fastQueue.append((id, text, speaker))
            Task { await self.drainFast() }
        }
        qualityQueue.append((id, text, speaker))
        Task { await self.drainQuality() }
    }

    func clearHistory() {
        history.removeAll()
        emitted.removeAll()
    }

    // MARK: - Hızlı hat (Apple)

    private func drainFast() async {
        guard !fastRunning else { return }
        fastRunning = true
        defer { fastRunning = false }

        while !fastQueue.isEmpty {
            let item = fastQueue.removeFirst()
            // Kaliteli hat bu cümleyi bizden önce bitirdiyse boşuna çevirme.
            guard !emitted.contains(item.id) else { continue }

            let started = DispatchTime.now()
            guard let result = await fallback.translateFast(item.text) else { continue }
            guard !emitted.contains(item.id) else { continue }

            emitted.insert(item.id)
            let elapsed = Log.ms(since: started)
            Log.info(.translate, "HIZLI Apple · \(elapsed) ms · \(item.speaker.map { "[\($0)] " } ?? "")\"\(item.text)\" -> \"\(result.text)\"")
            await onLine(item.id, result.text, item.speaker, "Apple", elapsed)
        }
    }

    // MARK: - Kaliteli hat (Claude, hızlı mod kapalıysa tek hat)

    private func drainQuality() async {
        guard !qualityRunning else { return }
        qualityRunning = true
        defer { qualityRunning = false }

        while !qualityQueue.isEmpty {
            let item = qualityQueue.removeFirst()
            let started = DispatchTime.now()
            let context = history.suffix(maxContext).map { $0 }

            let result = await fallback.translate(item.text, context: context)

            history.append(item.text)
            if history.count > 20 { history.removeFirst(history.count - 20) }

            let elapsed = Log.ms(since: started)
            Log.info(.translate, "\(result.backendName) · \(elapsed) ms · \(item.speaker.map { "[\($0)] " } ?? "")\"\(item.text)\" -> \"\(result.text)\"")

            if result.backendName == "ham" {
                await onNotice("Çeviri yapılamadı")
            }

            if emitted.contains(item.id) {
                // Hızlı hat zaten bastı — sadece düzelt.
                await onRefine(item.id, result.text, result.backendName, elapsed)
            } else {
                emitted.insert(item.id)
                await onLine(item.id, result.text, item.speaker, result.backendName, elapsed)
            }

            // Set'i tamamen boşaltmak kuyrukta bekleyen eski id'lerin tekrar
            // basılmasına yol açardı; sadece çok eskileri buduyoruz.
            if emitted.count > 200 {
                let cutoff = nextID > 100 ? nextID - 100 : 0
                emitted = emitted.filter { $0 >= cutoff }
            }
        }
    }
}
