// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.

import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia

/// Sistem sesini ScreenCaptureKit ile yakalar ve SpeechAnalyzer'ın istediği
/// AVAudioFormat'a çevirip dışarı verir. Video tarafı minimumda tutulur —
/// sadece ses gerekiyor, ama SCStream bir içerik filtresi istiyor.
final class AudioCapture: NSObject, @unchecked Sendable {

    enum CaptureError: LocalizedError {
        case noPermission
        case noDisplay
        case converterFailed

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return "Ekran Kaydı izni yok."
            case .noDisplay:
                return "Yakalanabilir ekran bulunamadı."
            case .converterFailed:
                return "Ses formatı dönüştürülemedi."
            }
        }
    }

    /// Dönüştürülmüş ses buffer'ları buradan akar.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Akış beklenmedik şekilde koparsa tetiklenir.
    var onStreamStopped: ((Error) -> Void)?

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "tr.iefsoftware.discordaltyazi.audio", qos: .userInitiated)

    /// SpeechAnalyzer'ın beklediği hedef format.
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    private(set) var isRunning = false

    // MARK: - İzin

    /// Ekran Kaydı izni verilmiş mi?
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Sistemden Ekran Kaydı izni ister (ilk çağrıda panel açar).
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Ekran listesi sorgusu bu makinede ~7-8 sn sürüyor (ölçüldü), oysa
    /// `startCapture` sadece ~180 ms. Bu yüzden ekranı açılışta bir kez alıp
    /// saklıyoruz; ⌘⇧T anında başlasın.
    nonisolated(unsafe) private static var cachedDisplay: SCDisplay?
    private static let cacheLock = NSLock()

    private static func storeDisplay(_ display: SCDisplay?) {
        cacheLock.lock(); cachedDisplay = display; cacheLock.unlock()
    }

    private static func loadDisplay() -> SCDisplay? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cachedDisplay
    }

    /// Ekran listesini çeker ve saklar.
    @discardableResult
    private static func fetchDisplay() async throws -> SCDisplay {
        let started = DispatchTime.now()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        Log.info(.audio, "Ekran listesi alındı (\(Log.ms(since: started)) ms)")
        storeDisplay(display)
        return display
    }

    /// Uygulama açılışında çağrılır; ekranı önden alıp saklar.
    static func prewarm() async {
        guard hasPermission() else { return }
        do {
            try await fetchDisplay()
        } catch {
            Log.warn(.audio, "Ekran listesi alınamadı: \(error.localizedDescription)")
        }
    }

    // MARK: - Yaşam döngüsü

    func start(targetFormat: AVAudioFormat) async throws {
        guard !isRunning else { return }
        guard Self.hasPermission() else { throw CaptureError.noPermission }

        self.targetFormat = targetFormat
        self.converter = nil
        self.converterInputFormat = nil

        // Saklanan ekranı kullan; yoksa (ilk açılış, ön ısıtma yetişmediyse) çek.
        let display: SCDisplay
        if let cached = Self.loadDisplay() {
            display = cached
        } else {
            display = try await Self.fetchDisplay()
        }

        // Kendi uygulamamızın sesini dışarıda bırak ki altyazı sesi geri beslenmesin.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video tarafını mümkün olan en küçüğe çek — CPU harcamasın.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps
        config.queueDepth = 6
        config.showsCursor = false

        let started = DispatchTime.now()
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        do {
            try await stream.startCapture()
        } catch {
            // Saklanan ekran geçersizleşmiş olabilir (monitör değişimi vb.) — bir kez tazele.
            Log.warn(.audio, "Saklanan ekranla başlatılamadı, liste tazeleniyor: \(error.localizedDescription)")
            Self.storeDisplay(nil)
            let fresh = try await Self.fetchDisplay()
            let freshFilter = SCContentFilter(display: fresh, excludingApplications: [], exceptingWindows: [])
            let freshStream = SCStream(filter: freshFilter, configuration: config, delegate: self)
            try freshStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try await freshStream.startCapture()
            self.stream = freshStream
            self.isRunning = true
            Log.info(.audio, "Yakalama başladı (tazelenmiş ekran, \(Log.ms(since: started)) ms)")
            return
        }
        Log.info(.audio, "Akış başlatıldı (\(Log.ms(since: started)) ms)")

        self.stream = stream
        self.isRunning = true
        Log.info(.audio, "Yakalama başladı (hedef format: \(targetFormat.sampleRate) Hz, \(targetFormat.channelCount) kanal)")
    }

    func stop() async {
        guard let stream else {
            isRunning = false
            return
        }
        self.stream = nil
        isRunning = false
        do {
            try await stream.stopCapture()
            Log.info(.audio, "Yakalama durduruldu")
        } catch {
            Log.warn(.audio, "Yakalama durdurulurken hata: \(error.localizedDescription)")
        }
        converter = nil
        converterInputFormat = nil
    }

    // MARK: - Dönüştürme

    /// CMSampleBuffer -> AVAudioPCMBuffer (kaynak formatında).
    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = sampleBuffer.formatDescription,
              var asbd = formatDescription.audioStreamBasicDescription else { return nil }
        guard let sourceFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }

    /// Kaynak buffer'ı hedef formata çevirir (gerekirse resample eder).
    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat else { return nil }

        if input.format == targetFormat { return input }

        if converter == nil || converterInputFormat != input.format {
            guard let newConverter = AVAudioConverter(from: input.format, to: targetFormat) else {
                Log.error(.audio, "AVAudioConverter kurulamadı: \(input.format) -> \(targetFormat)")
                return nil
            }
            newConverter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
            converter = newConverter
            converterInputFormat = input.format
            Log.info(.audio, "Dönüştürücü kuruldu: \(input.format.sampleRate) Hz/\(input.format.channelCount)ch -> \(targetFormat.sampleRate) Hz/\(targetFormat.channelCount)ch")
        }

        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }

        if status == .error {
            Log.warn(.audio, "Dönüştürme hatası: \(conversionError?.localizedDescription ?? "bilinmiyor")")
            return nil
        }
        guard output.frameLength > 0 else { return nil }
        return output
    }
}

// MARK: - SCStreamOutput

extension AudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let source = makePCMBuffer(from: sampleBuffer) else { return }
        guard let converted = convert(source) else { return }
        onBuffer?(converted)
    }
}

// MARK: - SCStreamDelegate

extension AudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error(.audio, "Akış koptu: \(error.localizedDescription)")
        self.stream = nil
        isRunning = false
        onStreamStopped?(error)
    }
}
