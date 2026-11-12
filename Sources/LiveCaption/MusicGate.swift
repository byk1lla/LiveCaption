// LiveCaption · © 2026 IEF Software · iefsoftware.tr
// MIT Lisansı — bkz. LICENSE.

import Foundation
import AVFoundation
import SoundAnalysis

/// Sesin müzik mi konuşma mı olduğunu Apple'ın yerel ses sınıflandırıcısıyla
/// (SoundAnalysis, 303 sınıf) ayırt eder. Şarkı sözlerinin altyazıya düşmesini
/// engellemek için kullanılır — müzik üstüne konuşulduğunda konuşma kazanır.
final class MusicGate: NSObject, @unchecked Sendable {

    /// Konuşma sayılan etiketler.
    private static let speechLabels: Set<String> = [
        "speech", "whispering", "shout", "children_shouting"
    ]

    /// Müzik sayılan etiketler (şarkı ve çalgılar dahil).
    private static let musicLabels: Set<String> = [
        "music", "singing", "rapping", "choir_singing", "humming", "singing_bowl",
        "guitar", "acoustic_guitar", "electric_guitar", "bass_guitar", "steel_guitar_slide_guitar",
        "guitar_strum", "guitar_tapping", "plucked_string_instrument", "bowed_string_instrument",
        "piano", "electric_piano", "keyboard_musical", "drum", "drum_kit", "bass_drum",
        "snare_drum", "brass_instrument", "wind_instrument", "vibraphone", "rattle_instrument"
    ]

    /// Konuşma bu eşiğin üstündeyse müzik ne olursa olsun kabul edilir.
    private let speechAcceptThreshold = 0.25
    /// Bu süre içindeki en yüksek skorlara bakılır.
    private let windowSeconds: TimeInterval = 3.0

    private let analysisQueue = DispatchQueue(label: "tr.iefsoftware.livecaption.sound", qos: .userInitiated)
    private let lock = NSLock()

    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private var framePosition: AVAudioFramePosition = 0
    private var samples: [(time: Date, speech: Double, music: Double)] = []
    private(set) var isRunning = false

    /// Son değerlendirmenin skorları — log için.
    private(set) var lastSpeechScore: Double = 0
    private(set) var lastMusicScore: Double = 0

    // MARK: - Yaşam döngüsü

    func start(format: AVAudioFormat) {
        stop()
        do {
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            // Daha sık sonuç → müzikten konuşmaya geçişi hızlı yakalayalım.
            request.overlapFactor = 0.5
            try analyzer.add(request, withObserver: self)

            lock.lock()
            streamAnalyzer = analyzer
            framePosition = 0
            samples.removeAll()
            isRunning = true
            lock.unlock()

            Log.info(.audio, "Müzik filtresi açık (SoundAnalysis, \(format.sampleRate) Hz)")
        } catch {
            Log.warn(.audio, "Müzik filtresi kurulamadı: \(error.localizedDescription) — filtre devre dışı")
        }
    }

    func stop() {
        lock.lock()
        let analyzer = streamAnalyzer
        streamAnalyzer = nil
        isRunning = false
        samples.removeAll()
        lock.unlock()
        analyzer?.completeAnalysis()
    }

    /// Ses buffer'ını sınıflandırıcıya besler (ses thread'inden çağrılır).
    func analyze(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let analyzer = streamAnalyzer else { lock.unlock(); return }
        let position = framePosition
        framePosition += AVAudioFramePosition(buffer.frameLength)
        lock.unlock()

        analysisQueue.async {
            analyzer.analyze(buffer, atAudioFramePosition: position)
        }
    }

    // MARK: - Karar

    /// Son pencerede konuşma var mı? Final cümle çeviriye gönderilmeden önce sorulur.
    func shouldAccept() -> Bool {
        lock.lock()
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        samples.removeAll { $0.time < cutoff }
        let speech = samples.map(\.speech).max() ?? 0
        let music = samples.map(\.music).max() ?? 0
        let hasData = !samples.isEmpty
        lastSpeechScore = speech
        lastMusicScore = music
        lock.unlock()

        // Henüz sınıflandırma gelmediyse engelleme — konuşma kaybetmek,
        // birkaç şarkı sözü göstermekten kötü.
        guard hasData else { return true }
        if speech >= speechAcceptThreshold { return true }
        return speech >= music
    }

    /// Son skorları "konuşma 0.04 / müzik 0.71" biçiminde döndürür.
    var scoreDescription: String {
        String(format: "konuşma %.2f / müzik %.2f", lastSpeechScore, lastMusicScore)
    }
}

// MARK: - SNResultsObserving

extension MusicGate: SNResultsObserving {
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }

        var speech = 0.0
        var music = 0.0
        for item in classification.classifications {
            if Self.speechLabels.contains(item.identifier) {
                speech = max(speech, item.confidence)
            } else if Self.musicLabels.contains(item.identifier) {
                music = max(music, item.confidence)
            }
        }

        lock.lock()
        samples.append((Date(), speech, music))
        if samples.count > 40 { samples.removeFirst(samples.count - 40) }
        lock.unlock()
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        Log.warn(.audio, "Ses sınıflandırma hatası: \(error.localizedDescription)")
    }

    func requestDidComplete(_ request: SNRequest) {}
}
