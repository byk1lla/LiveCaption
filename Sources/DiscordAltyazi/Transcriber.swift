// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.

import Foundation
import AVFoundation
import Speech

/// Ses thread'inden güvenle artırılabilen sayaç.
private final class AtomicDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Double = 0

    var value: Double {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func add(_ delta: Double) {
        lock.lock(); storage += delta; lock.unlock()
    }

    func reset() {
        lock.lock(); storage = 0; lock.unlock()
    }
}

/// AsyncStream continuation'ını iş parçacıkları arası güvenle taşır.
/// Ses buffer'ları ses thread'inden doğrudan yield edilmeli — araya aktör
/// hop'u koymak sırayı bozabilir (Task'ler FIFO garantisi vermez).
private final class InputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    func set(_ new: AsyncStream<AnalyzerInput>.Continuation?) {
        lock.lock()
        let old = continuation
        continuation = new
        lock.unlock()
        old?.finish()
    }

    func yield(_ input: AnalyzerInput) {
        lock.lock()
        let target = continuation
        lock.unlock()
        target?.yield(input)
    }

    func finish() { set(nil) }
}

/// Apple'ın yerel SpeechAnalyzer/SpeechTranscriber motorunu sarar.
/// Tamamen cihaz üzerinde çalışır, ağ gerektirmez.
@MainActor
final class TranscriptionEngine {

    enum EngineError: LocalizedError {
        case localeNotSupported(String)
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .localeNotSupported(let id):
                return "Bu Mac'te \(id) konuşma modeli desteklenmiyor."
            case .noAudioFormat:
                return "SpeechAnalyzer uygun bir ses formatı bildirmedi."
            }
        }
    }

    /// Geçici (interim) sonuç — İngilizce, soluk gösterilir.
    var onVolatile: ((String) -> Void)?
    /// Kesinleşmiş cümle — çeviriye gider.
    var onFinal: ((String) -> Void)?
    /// Kullanıcıya gösterilecek durum metni (model indirme vb.).
    var onStatus: ((String?) -> Void)?
    /// Kurtarılamayan hata.
    var onFatal: ((Error) -> Void)?

    /// Kaynak dil ayarlardan okunur; menüden değiştirilince yeniden kurulur.
    private var locale: Locale { Settings.shared.sourceLocale }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private let inputBox = InputBox()
    private var resultsTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

    /// Kullanıcı yakalamayı açık tutmak istiyor mu? (otomatik yeniden başlatma bunu dinler)
    private var shouldRun = false
    private var restartAttempt = 0

    private(set) var audioFormat: AVAudioFormat?

    /// Analizciye şimdiye kadar beslenen toplam ses süresi (sn).
    /// FINAL'in ses zamanıyla karşılaştırıp STT gecikmesini ölçüyoruz.
    private let fedSeconds = AtomicDouble()

    // MARK: - Hazırlık

    /// Dil modelini (gerekirse) indirir ve analizcinin istediği ses formatını döndürür.
    func prepare() async throws -> AVAudioFormat {
        let transcriber = makeTranscriber()

        let supported = await SpeechTranscriber.supportedLocales
        let wanted = locale.identifier(.bcp47)
        guard supported.contains(where: { $0.identifier(.bcp47) == wanted }) else {
            throw EngineError.localeNotSupported(wanted)
        }

        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == wanted }) {
            Log.info(.stt, "Dil modeli kurulu değil, indirme başlıyor: \(wanted)")
            onStatus?("Dil modeli indiriliyor…")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
                Log.info(.stt, "Dil modeli indirildi")
            }
            onStatus?(nil)
        }

        // Yerel yuvayı ayır — başka uygulamalar modeli boşaltmasın.
        _ = try? await AssetInventory.reserve(locale: locale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.noAudioFormat
        }
        audioFormat = format
        Log.info(.stt, "Analizci formatı: \(format.sampleRate) Hz, \(format.channelCount) kanal, \(format.commonFormat.rawValue)")
        return format
    }

    // MARK: - Yaşam döngüsü

    func start() async throws {
        shouldRun = true
        try await startInternal()
    }

    private func startInternal() async throws {
        await teardown()

        let transcriber = makeTranscriber()
        // Yüksek öncelik + modeli süreç boyunca bellekte tut: ilk sonuç ve
        // yeniden başlatma gecikmesi düşüyor.
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .high, modelRetention: .processLifetime)
        )

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.transcriber = transcriber
        self.analyzer = analyzer
        inputBox.set(continuation)

        fedSeconds.reset()
        try await analyzer.start(inputSequence: stream)
        Log.info(.stt, "SpeechAnalyzer başlatıldı — dil: \(Settings.shared.sourceDisplayName), hızlı tanıma: \(Settings.shared.fastRecognition ? "açık" : "kapalı")")

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    await MainActor.run {
                        self.restartAttempt = 0
                        if result.isFinal {
                            let lagMs = Int(max(0, self.fedSeconds.value - result.range.end.seconds) * 1000)
                            Log.info(.stt, "FINAL (+\(lagMs) ms ses gecikmesi): \(text)")
                            self.onFinal?(text)
                        } else {
                            self.onVolatile?(text)
                        }
                    }
                }
                // Akış normal bittiyse ve hâlâ çalışmamız gerekiyorsa yeniden kur.
                await MainActor.run { self.scheduleRestart(reason: "akış sonlandı") }
            } catch {
                await MainActor.run { self.scheduleRestart(reason: error.localizedDescription) }
            }
        }
    }

    /// Ses buffer'ını analizciye besler. Ses thread'inden doğrudan çağrılır;
    /// AsyncStream.Continuation.yield thread-safe ve çağrı sırasını korur.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        fedSeconds.add(Double(buffer.frameLength) / buffer.format.sampleRate)
        inputBox.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ayar değişince (ör. hızlı tanıma) analizciyi yeniden kurar.
    func restart() async {
        guard shouldRun else { return }
        do {
            try await startInternal()
            Log.info(.stt, "Analizci yeni ayarlarla yeniden kuruldu")
        } catch {
            Log.error(.stt, "Yeniden kurulamadı: \(error.localizedDescription)")
        }
    }

    func stop() async {
        shouldRun = false
        restartTask?.cancel()
        restartTask = nil
        await teardown()
        Log.info(.stt, "SpeechAnalyzer durduruldu")
    }

    private func teardown() async {
        resultsTask?.cancel()
        resultsTask = nil
        inputBox.finish()
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        analyzer = nil
        transcriber = nil
    }

    // MARK: - Yeniden başlatma

    private func scheduleRestart(reason: String) {
        guard shouldRun, restartTask == nil else { return }
        restartAttempt += 1
        let delay = min(Double(restartAttempt) * 0.75, 5.0)
        Log.warn(.stt, "Analizci yeniden başlatılıyor (\(restartAttempt). deneme, \(String(format: "%.1f", delay)) sn sonra) — sebep: \(reason)")

        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { self.restartTask = nil }
            guard await MainActor.run(body: { self.shouldRun }) else { return }
            do {
                try await self.startInternal()
            } catch {
                await MainActor.run {
                    if self.restartAttempt >= 5 {
                        self.onFatal?(error)
                    } else {
                        self.scheduleRestart(reason: error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: - Yardımcı

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // .fastResults: cümleyi daha erken kesinleştirir — canlı altyazıda
            // doğruluktan biraz veriyoruz, gecikmeden belirgin kazanıyoruz.
            // Menüden kapatılabilir.
            reportingOptions: Settings.shared.fastRecognition ? [.volatileResults, .fastResults] : [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }
}
