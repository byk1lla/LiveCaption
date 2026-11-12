// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.

import AppKit
import AVFoundation

/// Tüm parçaları birbirine bağlayan katman:
/// AudioCapture → TranscriptionEngine → TranslationPipeline → OverlayController
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let overlay = OverlayController()
    private let menuBar = MenuBarController()
    private let hotkeys = HotkeyManager()

    private let capture = AudioCapture()
    private let transcriber = TranscriptionEngine()
    private let musicGate = MusicGate()
    private let speakerDetector = SpeakerDetector()
    private let speakerTracker = SpeakerTracker()

    private let claude = ClaudeCLITranslator()
    private let apple = AppleTranslator()
    private var fallback: FallbackTranslator!
    private var pipeline: TranslationPipeline!

    private var isCapturing = false
    private var isStarting = false
    /// Menüde gösterilecek, arka plandan gelen son durum metni.
    private var backendDescription = "Claude (beklemede)"

    // MARK: - Uygulama yaşam döngüsü

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info(.app, "DiscordAltyazı başlatılıyor")

        fallback = FallbackTranslator(claude: claude, apple: apple)
        pipeline = TranslationPipeline(
            fallback: fallback,
            onLine: { id, text, speaker, backend, elapsedMs in
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.overlay.appendLine(id: id, speaker: speaker, text: text)
                    Log.info(.overlay, "Ekrana düştü (\(backend), \(elapsedMs) ms)")
                }
            },
            onRefine: { id, text, backend, elapsedMs in
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.overlay.refineLine(id: id, text: text)
                    Log.info(.overlay, "Satır düzeltildi (\(backend), \(elapsedMs) ms)")
                }
            },
            onNotice: { notice in
                await MainActor.run { [weak self] in
                    self?.overlay.flashNotice(notice)
                }
            }
        )

        setupMenu()
        setupHotkeys()

        if Settings.shared.overlayVisible {
            overlay.show()
        }
        menuBar.setOverlayVisible(Settings.shared.overlayVisible)
        menuBar.setCapturing(false)

        apple.onStatus = { [weak self] status in
            self?.overlay.setStatus(status)
        }

        // Arka uç durumunu menüye yansıt.
        Task { [weak self] in
            guard let self else { return }
            await self.fallback.setStatusObserver { _, _ in
                await self.refreshBackendDescription()
            }
            await self.refreshBackendDescription()
        }

        // ÖN ISITMA: yakalama başlamadan, uygulama açılır açılmaz Claude sürecini ayağa kaldır.
        Task { [weak self] in
            guard let self else { return }
            await self.fallback.prepare()
            await self.refreshBackendDescription()
        }

        // Konuşmacı adını Discord'un arayüzünden oku.
        speakerDetector.onSample = { [weak self] name in
            self?.speakerTracker.record(name)
        }
        speakerDetector.start()
        if let problem = speakerDetector.problem {
            Log.warn(.app, problem)
        }

        // Ekran listesini önden çek — ⌘⇧T'ye basınca beklemeyelim.
        Task { await AudioCapture.prewarm() }

        // Menüdeki kaynak dil listesini doldur.
        Task { [weak self] in
            await self?.reloadLanguageOptions()
        }

        // İzin kontrolü + dil modeli hazırlığı.
        Task { [weak self] in
            await self?.checkPermissionAndPrepareModel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info(.app, "Kapanıyor — tüm süreçler temizleniyor")
        hotkeys.unregisterAll()
        speakerDetector.stop()
        // CLI süreçlerini SENKRON öldür: arkada zombi kalmasın. Burada aktör
        // beklemek ana iş parçacığını kilitler (transcriber.stop() @MainActor),
        // o yüzden pid'ler üzerinden doğrudan sinyal gönderiyoruz.
        ClaudeProcessHandle.terminateAllSynchronously()
        // Ses akışı ve analizci süreçle birlikte zaten ölüyor; yine de deneriz.
        Task { [capture] in await capture.stop() }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Kurulum

    private func setupMenu() {
        menuBar.backendDescriptionProvider = { [weak self] in
            self?.backendDescription ?? "—"
        }
        menuBar.onToggleCapture = { [weak self] in self?.toggleCapture() }
        menuBar.onToggleOverlay = { [weak self] in self?.toggleOverlay() }
        menuBar.onSelectBackend = { [weak self] backend in
            guard let self else { return }
            Settings.shared.backend = backend
            self.menuBar.refreshChecks()
            Task {
                await self.fallback.setPreferred(backend)
                await self.refreshBackendDescription()
            }
        }
        menuBar.onSelectFontSize = { [weak self] size in
            Settings.shared.fontSize = size
            self?.overlay.applySettings()
            self?.menuBar.refreshChecks()
        }
        menuBar.onSelectPosition = { [weak self] position in
            Settings.shared.position = position
            self?.overlay.applySettings()
            self?.menuBar.refreshChecks()
        }
        menuBar.onToggleMusicFilter = { [weak self] in
            Settings.shared.musicFilter.toggle()
            Log.info(.app, "Müzik filtresi: \(Settings.shared.musicFilter ? "açık" : "kapalı")")
            self?.menuBar.refreshChecks()
        }
        menuBar.onToggleSpeakerNames = { [weak self] in
            Settings.shared.showSpeakerNames.toggle()
            Log.info(.app, "Konuşmacı adı: \(Settings.shared.showSpeakerNames ? "açık" : "kapalı")")
            self?.menuBar.refreshChecks()
        }
        menuBar.onToggleFastRecognition = { [weak self] in
            Settings.shared.fastRecognition.toggle()
            Log.info(.app, "Hızlı tanıma: \(Settings.shared.fastRecognition ? "açık" : "kapalı")")
            self?.menuBar.refreshChecks()
            // Seçenek analizci kurulurken veriliyor — yeniden kur.
            Task { [weak self] in await self?.transcriber.restart() }
        }
        menuBar.onSelectLanguage = { [weak self] identifier in
            self?.changeLanguage(to: identifier)
        }
        menuBar.onToggleFastMode = { [weak self] in
            Settings.shared.fastMode.toggle()
            Log.info(.app, "Hızlı mod: \(Settings.shared.fastMode ? "açık" : "kapalı")")
            self?.menuBar.refreshChecks()
        }
        menuBar.onQuit = { NSApp.terminate(nil) }
    }

    private func setupHotkeys() {
        hotkeys.registerDefaults(
            toggleCapture: { [weak self] in
                Log.info(.app, "kısayol: ⌘⇧T")
                self?.toggleCapture()
            },
            toggleOverlay: { [weak self] in self?.toggleOverlay() }
        )
    }

    private func refreshBackendDescription() async {
        let description = await fallback.activeDescription()
        backendDescription = description
        menuBar.refreshChecks()
    }

    // MARK: - Dil

    private func reloadLanguageOptions() async {
        let options = await LanguageCatalog.options()
        menuBar.setLanguageOptions(options)
        Log.info(.app, "\(options.count) kaynak dil bulundu, seçili: \(Settings.shared.sourceDisplayName)")
    }

    /// Kaynak dili değiştirir: yakalamayı durdurur, STT modelini ve her iki
    /// çeviri arka ucunu yeni dile göre kurar, sonra kaldığı yerden devam eder.
    private func changeLanguage(to identifier: String) {
        guard identifier != Settings.shared.sourceLanguage else { return }
        Task { [weak self] in
            guard let self else { return }
            let wasCapturing = self.isCapturing
            if wasCapturing { await self.stopCapture() }

            Settings.shared.sourceLanguage = identifier
            let name = Settings.shared.sourceDisplayName
            Log.info(.app, "Kaynak dil: \(name)")

            self.overlay.clear()
            if !self.overlay.visible { self.overlay.show() }
            self.overlay.setStatus("Dil değiştiriliyor: \(name)…")
            self.menuBar.refreshChecks()

            // Konuşma modeli inmemişse burada iner.
            do {
                _ = try await self.transcriber.prepare()
            } catch {
                Log.error(.stt, "Yeni dil hazırlanamadı: \(error.localizedDescription)")
                self.overlay.setStatus("Dil hazırlanamadı: \(error.localizedDescription)")
            }

            // Claude promptunda dil adı geçiyor → süreçler yeniden kurulur.
            await self.fallback.setSourceLanguage(name)

            self.overlay.setStatus(nil)
            await self.reloadLanguageOptions()
            await self.refreshBackendDescription()

            if wasCapturing { await self.startCapture() }
        }
    }

    // MARK: - İzin ve model

    private func checkPermissionAndPrepareModel() async {
        guard AudioCapture.hasPermission() else {
            Log.warn(.app, "Ekran Kaydı izni yok")
            overlay.show()
            overlay.setStatus("Sistem Ayarları > Gizlilik > Ekran Kaydı'ndan izin ver, sonra uygulamayı yeniden başlat")
            AudioCapture.requestPermission()
            return
        }

        transcriber.onStatus = { [weak self] status in
            self?.overlay.setStatus(status)
        }
        do {
            _ = try await transcriber.prepare()
            Log.info(.app, "Konuşma modeli hazır")
        } catch {
            Log.error(.stt, "Model hazırlanamadı: \(error.localizedDescription)")
            overlay.setStatus("Konuşma modeli hazırlanamadı: \(error.localizedDescription)")
        }
    }

    // MARK: - Yakalama

    private func toggleCapture() {
        if isCapturing {
            Task { await stopCapture() }
        } else {
            Task { await startCapture() }
        }
    }

    private func startCapture() async {
        guard !isCapturing, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        guard AudioCapture.hasPermission() else {
            overlay.show()
            overlay.setStatus("Sistem Ayarları > Gizlilik > Ekran Kaydı'ndan izin ver, sonra uygulamayı yeniden başlat")
            AudioCapture.requestPermission()
            return
        }

        do {
            let format = try await transcriber.prepare()

            transcriber.onVolatile = { [weak self] text in
                self?.overlay.setInterim(text)
            }
            transcriber.onFinal = { [weak self] text in
                guard let self else { return }
                // Müzik/şarkı sözü ise çeviriye hiç gönderme.
                if Settings.shared.musicFilter, !self.musicGate.shouldAccept() {
                    Log.info(.stt, "Müzik algılandı (\(self.musicGate.scoreDescription)), çevrilmedi: \(text)")
                    return
                }
                let speaker = Settings.shared.showSpeakerNames ? self.speakerTracker.dominantSpeaker() : nil
                Task { await self.pipeline.enqueue(text, speaker: speaker) }
            }
            transcriber.onFatal = { [weak self] error in
                self?.overlay.flashNotice("Konuşma motoru hatası: \(error.localizedDescription)")
            }

            try await transcriber.start()

            capture.onBuffer = { [weak self] buffer in
                guard let self else { return }
                self.transcriber.feed(buffer)
                self.musicGate.analyze(buffer)
            }
            capture.onStreamStopped = { [weak self] error in
                Task { @MainActor in
                    self?.overlay.flashNotice("Ses akışı koptu: \(error.localizedDescription)")
                    await self?.stopCapture()
                }
            }

            if Settings.shared.musicFilter {
                musicGate.start(format: format)
            }
            try await capture.start(targetFormat: format)

            isCapturing = true
            await fallback.setKeepWarm(true)
            menuBar.setCapturing(true)
            if !overlay.visible { overlay.show() }
            overlay.setStatus(nil)
            Log.info(.app, "Yakalama açık")
        } catch {
            Log.error(.app, "Yakalama başlatılamadı: \(error.localizedDescription)")
            overlay.show()
            if case AudioCapture.CaptureError.noPermission = error {
                overlay.setStatus("Sistem Ayarları > Gizlilik > Ekran Kaydı'ndan izin ver, sonra uygulamayı yeniden başlat")
            } else {
                overlay.flashNotice("Başlatılamadı: \(error.localizedDescription)")
            }
            await stopCapture()
        }
    }

    private func stopCapture() async {
        guard isCapturing || capture.isRunning else {
            menuBar.setCapturing(false)
            return
        }
        await capture.stop()
        await transcriber.stop()
        await fallback.setKeepWarm(false)
        musicGate.stop()
        await pipeline.clearHistory()
        speakerTracker.clear()
        isCapturing = false
        menuBar.setCapturing(false)
        overlay.setInterim("")
        Log.info(.app, "Yakalama kapalı")
    }

    private func toggleOverlay() {
        overlay.toggle()
        Settings.shared.overlayVisible = overlay.visible
        menuBar.setOverlayVisible(overlay.visible)
    }
}
