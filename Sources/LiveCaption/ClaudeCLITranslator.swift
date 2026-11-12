// LiveCaption · © 2026 IEF Software · iefsoftware.tr
// MIT Lisansı — bkz. LICENSE.

import Foundation

/// Kullanıcının kurulu `claude` CLI'ını kalıcı bir süreç olarak çalıştırır.
/// API anahtarı kullanılmaz, OAuth token'ına dokunulmaz — sadece CLI çağrılır,
/// yani kullanıcının kendi aboneliği üzerinden çalışır.
///
/// Her cümle için yeni süreç açmak yerine tek bir `--input-format stream-json`
/// süreci canlı tutulur; bağlam şişmeye başlayınca arka planda yeni süreç
/// hazırlanıp kesintisiz devralır (hot swap).
actor ClaudeCLITranslator: Translator {

    nonisolated let name = "Claude"

    // MARK: - Sabitler

    /// Kaç çeviriden sonra yedek süreç hazırlanmaya başlasın.
    private let swapThreshold = 35
    /// Ön ısıtma için tanınan süre.
    private let warmupTimeout: Double = 10
    /// Isınma başarısız olursa ne kadar sonra tekrar denensin.
    private let retryDelay: Double = 30

    /// Sistem promptu kaynak dile göre kurulur. Prompt süreç başlarken sabitlendiği
    /// için dil değişince süreçlerin yeniden başlatılması gerekiyor.
    private static func systemPrompt(sourceLanguage: String) -> String {
        """
        Sen canlı altyazı çevirmenisin. Gelen \(sourceLanguage) konuşma Discord'da oyun oynayan/sohbet \
        eden insanlardan. Doğal, günlük, akıcı Türkçeye çevir. Argo ve küfürü sansürleme, Türkçedeki \
        doğal karşılığını kullan. Oyun terimlerini (clutch, rush, nerf, gank, lobby vb.) gerekiyorsa \
        orijinal bırak. Kısa cümleler çoğu zaman oyun içi komuttur ("cover me", "push", "fall back", \
        "reload", "on me") — bunları oyuncu ağzıyla çevir, birebir sözlük çevirisi yapma. \
        Sadece çeviriyi döndür, açıklama, tırnak veya not ekleme. \
        Mesaj formatı: 'ÖNCEKİ: ... / ÇEVİR: ...'; sadece ÇEVİR kısmını çevir.
        """
    }

    /// Aktif süreçlerin promptunda kullanılan dil adı.
    private var sourceLanguageName = "İngilizce"

    /// Menüden dil değişince çağrılır: süreçleri kapatıp yeni promptla kurar.
    func setSourceLanguage(_ name: String) async {
        guard name != sourceLanguageName else { return }
        sourceLanguageName = name
        Log.info(.claude, "Kaynak dil değişti (\(name)) — süreçler yeni promptla yeniden kuruluyor")
        await shutdown()
        await prepare()
    }

    // MARK: - Durum

    private var active: ClaudeProcessHandle?
    private var standby: ClaudeProcessHandle?
    private var translationCount = 0

    private var state: BackendReadiness = .idle
    private var statusObserver: (@Sendable (BackendReadiness) async -> Void)?

    private var prepareTask: Task<Void, Never>?
    private var standbyTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

    private var cliPath: String?

    var readiness: BackendReadiness { state }

    func setStatusObserver(_ observer: @escaping @Sendable (BackendReadiness) async -> Void) {
        statusObserver = observer
    }

    private func setState(_ newState: BackendReadiness) async {
        guard state != newState else { return }
        state = newState
        await statusObserver?(newState)
    }

    // MARK: - CLI yolu

    /// `claude` CLI'ını PATH'te ve bilinen konumlarda arar.
    static func locateCLI() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            NSHomeDirectory() + "/.bun/bin/claude",
            "/run/current-system/sw/bin/claude"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Son çare: `which claude` (giriş kabuğu PATH'iyle)
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/zsh")
        which.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            which.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        } catch {
            Log.warn(.claude, "`which claude` çalıştırılamadı: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Hazırlık / ön ısıtma

    func prepare() async {
        guard prepareTask == nil, active == nil else { return }
        retryTask?.cancel(); retryTask = nil

        guard let path = cliPath ?? Self.locateCLI() else {
            Log.error(.claude, "`claude` CLI bulunamadı. Terminalde bir kez `claude` çalıştırıp giriş yapmalısın.")
            await setState(.unavailable("CLI bulunamadı"))
            return
        }
        cliPath = path

        await setState(.warming)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.bootActive(path: path)
        }
        prepareTask = task
        await task.value
        prepareTask = nil
    }

    private func bootActive(path: String) async {
        let handle = ClaudeProcessHandle(cliPath: path,
                                         systemPrompt: Self.systemPrompt(sourceLanguage: sourceLanguageName),
                                         label: "aktif")
        do {
            let warmupMs = try await withTimeout(warmupTimeout) {
                try await handle.startAndWarmUp()
            }
            active = handle
            translationCount = 0
            await setState(.ready)
            Log.info(.claude, "Aktif süreç hazır — ısınma \(warmupMs) ms")
            observeDeath(of: handle, isStandby: false)
        } catch {
            Log.error(.claude, "Ön ısıtma başarısız: \(error.localizedDescription)")
            await handle.shutdown()
            await setState(.unavailable("ısınma başarısız"))
            scheduleRetry(path: path)
        }
    }

    private func scheduleRetry(path: String) {
        guard retryTask == nil else { return }
        Log.info(.claude, "\(Int(retryDelay)) sn sonra tekrar denenecek")
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.retryDelay ?? 30))
            guard let self, !Task.isCancelled else { return }
            await self.clearRetryTask()
            await self.prepare()
        }
    }

    private func clearRetryTask() { retryTask = nil }

    // MARK: - Çeviri

    func translate(_ text: String, context: [String]) async throws -> String {
        guard let handle = active else {
            throw NSError(domain: "LiveCaption", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Claude süreci hazır değil"])
        }

        let message = Self.buildMessage(text: text, context: context)
        do {
            let reply = try await handle.send(message)
            translationCount += 1
            await maybeRotate()
            return Self.cleanup(reply)
        } catch {
            // Süreç ölmüş olabilir — yedek varsa hemen devral.
            await handleActiveFailure()
            throw error
        }
    }

    /// 'ÖNCEKİ: ... / ÇEVİR: ...' formatında mesaj kurar.
    private static func buildMessage(text: String, context: [String]) -> String {
        if context.isEmpty {
            return "ÇEVİR: \(text)"
        }
        let previous = context.joined(separator: " | ")
        return "ÖNCEKİ: \(previous) / ÇEVİR: \(text)"
    }

    /// Model yine de tırnak/ön ek eklerse temizle.
    private static func cleanup(_ reply: String) -> String {
        var s = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["ÇEVİR:", "CEVIR:", "Çeviri:", "Translation:"] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        if s.count > 1, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    // MARK: - Kesintisiz süreç yenileme (hot swap)

    /// Eşik aşıldıysa yedek süreç başlat; yedek hazırsa devral.
    private func maybeRotate() async {
        // 1) Hazır bekleyen yedek varsa ve aktif istek bittiyse (buradayız, bitti) devral.
        if let standby, standby.isReady {
            let old = active
            active = standby
            self.standby = nil
            translationCount = 0
            observeDeath(of: standby, isStandby: false)
            Log.info(.swap, "Yedek süreç devraldı, eski süreç kapatılıyor")
            if let old { Task { await old.shutdown() } }
            await setState(.ready)
            return
        }

        // 2) Eşiğe gelindiyse ve ortada yedek yoksa arka planda yeni süreç hazırla.
        if translationCount >= swapThreshold, standby == nil, standbyTask == nil, let path = cliPath {
            Log.info(.swap, "\(translationCount). çeviri — yedek süreç arka planda hazırlanıyor")
            standbyTask = Task { [weak self] in
                await self?.bootStandby(path: path)
            }
        }
    }

    private func bootStandby(path: String) async {
        defer { standbyTask = nil }
        let handle = ClaudeProcessHandle(cliPath: path,
                                         systemPrompt: Self.systemPrompt(sourceLanguage: sourceLanguageName),
                                         label: "yedek")
        do {
            let warmupMs = try await withTimeout(warmupTimeout) {
                try await handle.startAndWarmUp()
            }
            standby = handle
            Log.info(.swap, "Yedek süreç hazır — ısınma \(warmupMs) ms (devralma bir sonraki çeviriden sonra)")
        } catch {
            Log.warn(.swap, "Yedek süreç hazırlanamadı: \(error.localizedDescription) — eski süreçle devam")
            await handle.shutdown()
            // 30 sn sonra tekrar dene: sayacı eşiğin biraz altına çekmek yerine
            // basitçe bekleyip yeniden tetikleniyoruz.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(self?.retryDelay ?? 30))
                await self?.retryStandbyIfNeeded()
            }
        }
    }

    private func retryStandbyIfNeeded() async {
        guard standby == nil, standbyTask == nil, translationCount >= swapThreshold, let path = cliPath else { return }
        Log.info(.swap, "Yedek süreç yeniden deneniyor")
        standbyTask = Task { [weak self] in
            await self?.bootStandby(path: path)
        }
    }

    /// Aktif süreç çökerse: yedek hazırsa devral, değilse Apple'a düşülsün.
    private func handleActiveFailure() async {
        guard let dead = active else { return }
        guard !dead.isAlive else { return }

        active = nil
        Task { await dead.shutdown() }

        if let standby, standby.isReady {
            Log.warn(.swap, "Aktif süreç öldü — yedek devralıyor")
            active = standby
            self.standby = nil
            translationCount = 0
            observeDeath(of: active!, isStandby: false)
            await setState(.ready)
        } else {
            Log.warn(.claude, "Aktif süreç öldü, yedek yok — Apple'a düşülüyor, yeniden başlatılacak")
            await setState(.unavailable("süreç öldü"))
            if let path = cliPath {
                Task { [weak self] in await self?.bootActive(path: path) }
            }
        }
    }

    private func observeDeath(of handle: ClaudeProcessHandle, isStandby: Bool) {
        Task { [weak self] in
            await handle.waitUntilExit()
            guard let self else { return }
            await self.processDied(handle, isStandby: isStandby)
        }
    }

    private func processDied(_ handle: ClaudeProcessHandle, isStandby: Bool) async {
        if active === handle {
            Log.warn(.claude, "Aktif süreç beklenmedik şekilde sonlandı")
            await handleActiveFailure()
        } else if standby === handle {
            Log.warn(.swap, "Yedek süreç sonlandı")
            standby = nil
        }
    }

    // MARK: - Kapanış

    func shutdown() async {
        prepareTask?.cancel(); prepareTask = nil
        standbyTask?.cancel(); standbyTask = nil
        retryTask?.cancel(); retryTask = nil

        let handles = [active, standby].compactMap { $0 }
        active = nil
        standby = nil
        for handle in handles {
            await handle.shutdown()
        }
        await setState(.idle)
        Log.info(.claude, "Tüm Claude süreçleri kapatıldı")
    }
}
