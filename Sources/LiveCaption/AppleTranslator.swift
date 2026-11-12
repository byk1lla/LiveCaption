// LiveCaption · © 2026 IEF Software · iefsoftware.tr
// MIT Lisansı — bkz. LICENSE.

import Foundation
import AppKit
import SwiftUI
import Translation

/// Apple'ın yerel çeviri motoru (en → tr). Yedek arka uç.
/// Önce SwiftUI'sız `TranslationSession(installedSource:target:)` denenir;
/// olmazsa gizli bir SwiftUI view içinden `.translationTask` ile oturum alınır
/// ve uygulama boyunca canlı tutulur.
@MainActor
final class AppleTranslator: Translator {

    nonisolated let name = "Apple"

    enum AppleError: LocalizedError {
        case notReady
        case unsupported

        var errorDescription: String? {
            switch self {
            case .notReady: return "Apple çeviri oturumu henüz hazır değil."
            case .unsupported: return "Bu Mac'te en→tr çeviri desteklenmiyor."
            }
        }
    }

    /// Kaynak dil ayarlardan okunur.
    private var source: Locale.Language { Locale.Language(identifier: Settings.shared.sourceBaseCode) }
    private let target = Locale.Language(identifier: "tr")

    private var session: TranslationSession?
    private var hostWindow: NSWindow?
    private var state: BackendReadiness = .idle
    private var preparing = false
    private var keepWarmTask: Task<Void, Never>?

    /// Dil paketi indiriliyorsa overlay'de gösterilecek metin.
    var onStatus: ((String?) -> Void)?

    var readiness: BackendReadiness { state }

    // MARK: - Hazırlık

    /// Kaynak dil değişince oturumu baştan kurar.
    func reconfigure() async {
        session = nil
        hostWindow?.orderOut(nil)
        hostWindow = nil
        state = .idle
        await prepare()
    }

    func prepare() async {
        guard !preparing, session == nil else { return }
        preparing = true
        defer { preparing = false }

        state = .warming

        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)

        switch status {
        case .installed:
            break
        case .supported:
            Log.info(.apple, "\(Settings.shared.sourceBaseCode)→tr dil paketi kurulu değil, indirme tetikleniyor")
            onStatus?("Apple çeviri paketi indiriliyor…")
            await triggerDownload()
            onStatus?(nil)
        case .unsupported:
            Log.error(.apple, "\(Settings.shared.sourceBaseCode)→tr çeviri bu sistemde desteklenmiyor")
            state = .unavailable("bu dil desteklenmiyor")
            return
        @unknown default:
            break
        }

        // 1) SwiftUI'sız doğrudan oturum.
        let direct = TranslationSession(installedSource: source, target: target)
        do {
            try await direct.prepareTranslation()
            session = direct
            await warmUp(direct)
            state = .ready
            return
        } catch {
            Log.warn(.apple, "Doğrudan oturum kurulamadı (\(error.localizedDescription)) — SwiftUI yoluna geçiliyor")
        }

        // 2) Gizli SwiftUI view üzerinden oturum.
        await makeHostedSession()
    }

    /// Dil paketini indirmek için geçici bir oturum üzerinden hazırlık tetikler.
    private func triggerDownload() async {
        let temp = TranslationSession(installedSource: source, target: target)
        do {
            try await temp.prepareTranslation()
            Log.info(.apple, "Dil paketi hazır")
        } catch {
            Log.warn(.apple, "Dil paketi indirilemedi: \(error.localizedDescription)")
        }
    }

    /// 1x1 piksellik, ekran dışı bir pencerede SwiftUI host kurar ve oturumu yakalar.
    private func makeHostedSession() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let configuration = TranslationSession.Configuration(source: source, target: target)
            let view = TranslationHostView(configuration: configuration) { [weak self] session in
                guard let self else { return }
                self.session = session
                self.state = .ready
                Log.info(.apple, "SwiftUI üzerinden TranslationSession alındı")
                Task { @MainActor in await self.warmUp(session) }
                if !resumed { resumed = true; continuation.resume() }
            }

            let window = NSWindow(
                contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: view)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.level = .normal
            window.orderBack(nil)
            hostWindow = window

            // Oturum hiç gelmezse takılı kalmayalım.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if !resumed {
                    resumed = true
                    if self.session == nil {
                        self.state = .unavailable("oturum açılamadı")
                        Log.error(.apple, "TranslationSession 5 sn içinde alınamadı")
                    }
                    continuation.resume()
                }
            }
        }
    }

    /// Sessiz ısınma: ilk gerçek cümle soğuk çağrının bedelini ödemesin.
    /// Ölçüldü: ısınmadan ~660 ms, ısındıktan sonra ~55 ms.
    private func warmUp(_ session: TranslationSession) async {
        let started = DispatchTime.now()
        do {
            _ = try await session.translate("Hello.")
            Log.info(.apple, "Çeviri oturumu hazır — ısınma \(Log.ms(since: started)) ms")
        } catch {
            Log.warn(.apple, "Isınma çevirisi başarısız: \(error.localizedDescription)")
        }
    }

    /// Yakalama açıkken oturumu sıcak tutar. Ölçüldü: 30 sn boştan sonra ilk
    /// çeviri ~800 ms, sıcakken ~45 ms.
    func setKeepWarm(_ on: Bool) {
        keepWarmTask?.cancel()
        keepWarmTask = nil
        guard on else { return }
        keepWarmTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                guard let session = self.session else { continue }
                _ = try? await session.translate("ok")
            }
        }
    }

    // MARK: - Çeviri

    func translate(_ text: String, context: [String]) async throws -> String {
        if session == nil, state != .warming {
            await prepare()
        }
        guard let session else { throw AppleError.notReady }
        let response = try await session.translate(text)
        return response.targetText
    }

    func shutdown() async {
        session = nil
        hostWindow?.orderOut(nil)
        hostWindow = nil
        state = .idle
    }
}

/// Gizli SwiftUI host — sadece bir TranslationSession üretmek için var.
/// Yapılandırma hiç değişmediği için @State'e gerek yok (ayrıca @State artık
/// bir makro ve makro eklentisi Command Line Tools'ta gelmiyor).
private struct TranslationHostView: View {
    let configuration: TranslationSession.Configuration
    let onSession: (TranslationSession) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                onSession(session)
            }
    }
}
