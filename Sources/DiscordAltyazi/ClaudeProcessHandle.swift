// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.

import Foundation

/// Tek bir kalıcı `claude` CLI sürecini yönetir.
/// stdin'e satır satır stream-json yazar, stdout'tan gelen `result` olaylarını
/// bekleyen isteklerle SIRAYLA eşleştirir.
final class ClaudeProcessHandle: @unchecked Sendable {

    enum HandleError: LocalizedError {
        case notRunning
        case died(Int32)
        case badReply(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: return "Claude süreci çalışmıyor."
            case .died(let code): return "Claude süreci sonlandı (kod \(code))."
            case .badReply(let detail): return "Claude beklenmedik yanıt verdi: \(detail)"
            }
        }
    }

    /// Yaşayan tüm CLI süreçlerinin pid'leri — uygulama kapanırken
    /// ana iş parçacığını bloklamadan, senkron olarak temizlenebilsin diye.
    nonisolated(unsafe) private static var livePIDs: Set<Int32> = []
    private static let registryLock = NSLock()

    private static func registerPID(_ pid: Int32) {
        registryLock.lock(); livePIDs.insert(pid); registryLock.unlock()
    }

    private static func unregisterPID(_ pid: Int32) {
        registryLock.lock(); livePIDs.remove(pid); registryLock.unlock()
    }

    /// Kapanışta çağrılır: önce SIGTERM, kısa bekleme, sonra SIGKILL.
    /// Tamamen senkron — aktör beklemez, ana iş parçacığı kilitlenmez.
    static func terminateAllSynchronously() {
        registryLock.lock()
        let pids = livePIDs
        livePIDs.removeAll()
        registryLock.unlock()

        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        usleep(400_000)
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        Log.info(.claude, "Kapanışta \(pids.count) CLI süreci temizlendi")
    }

    private let cliPath: String
    private let systemPrompt: String
    private let label: String

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()

    private let lock = NSLock()
    private var pending: [CheckedContinuation<String, Error>] = []
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var lineBuffer = Data()
    private var alive = false
    private var ready = false
    private var launchedAt: DispatchTime?

    /// Kilidi senkron bir kapsamda tutar — async bağlamdan doğrudan
    /// `lock()` çağırmak Swift 6'da hata.
    @inline(__always)
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    init(cliPath: String, systemPrompt: String, label: String) {
        self.cliPath = cliPath
        self.systemPrompt = systemPrompt
        self.label = label
    }

    // MARK: - Durum

    var isAlive: Bool { locked { alive } }

    var isReady: Bool { locked { alive && ready } }

    // MARK: - Başlatma + ön ısıtma

    /// Süreci başlatır, sessiz bir ısınma isteği gönderir, yanıtı atar.
    /// Dönen değer: süreç başladı → ilk yanıt arası geçen süre (ms).
    @discardableResult
    func startAndWarmUp() async throws -> Int {
        try launch()
        // Isınma isteği: yanıt ekrana basılmaz, bağlam geçmişine ve sayaca eklenmez.
        _ = try await send("ÇEVİR: Hello.", countsAsReady: false)
        let elapsed = Log.ms(since: launchedAt ?? DispatchTime.now())
        locked { ready = true }
        Log.info(.claude, "[\(label)] ısınma tamam: \(elapsed) ms")
        return elapsed
    }

    private func launch() throws {
        let workDir = Self.scratchDirectory()

        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--model", "haiku",
            "--effort", "low",
            "--tools", "",                    // tüm araçlar kapalı
            "--no-session-persistence",       // oturum diske yazılmasın
            "--strict-mcp-config",            // MCP sunucuları yüklenmesin (hız)
            "--setting-sources", "",          // kullanıcı/proje ayarları yüklenmesin
            "--disable-slash-commands",
            "--system-prompt", systemPrompt
        ]
        process.currentDirectoryURL = workDir
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        // .app içinden açılınca PATH dar oluyor; node/claude bulunabilsin.
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", NSHomeDirectory() + "/.local/bin"]
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [currentPath]).filter { !$0.isEmpty }.joined(separator: ":")
        // Düşünme kapalı → canlı altyazı için gecikme ~2 sn'den ~1 sn'ye iniyor.
        env["MAX_THINKING_TOKENS"] = "0"
        env["DISABLE_TELEMETRY"] = "1"
        env["DISABLE_AUTOUPDATER"] = "1"
        env["DISABLE_ERROR_REPORTING"] = "1"
        env["DISABLE_NON_ESSENTIAL_MODEL_CALLS"] = "1"
        env["DISABLE_COST_WARNINGS"] = "1"
        process.environment = env

        process.terminationHandler = { [weak self] proc in
            self?.handleTermination(status: proc.terminationStatus)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.ingest(data)
        }

        lock.lock()
        alive = true
        ready = false
        launchedAt = DispatchTime.now()
        lock.unlock()

        try process.run()
        Self.registerPID(process.processIdentifier)
        Log.info(.claude, "[\(label)] süreç başlatıldı (pid \(process.processIdentifier))")
    }

    /// Her süreç boş bir çalışma dizininde koşar — proje CLAUDE.md'si yüklenmesin.
    private static func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiscordAltyazi-claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - İstek / yanıt

    /// Bir mesaj gönderir ve karşılık gelen `result` olayını bekler.
    func send(_ message: String, countsAsReady: Bool = true) async throws -> String {
        if countsAsReady, !isReady { throw HandleError.notRunning }
        if !isAlive { throw HandleError.notRunning }

        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": message]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var line = data
        line.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard alive else {
                lock.unlock()
                continuation.resume(throwing: HandleError.notRunning)
                return
            }
            pending.append(continuation)
            lock.unlock()

            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: line)
            } catch {
                // Yazamadıysak SADECE az önce eklediğimiz isteği düşür (sondaki).
                lock.lock()
                let toFail = pending.popLast()
                lock.unlock()
                toFail?.resume(throwing: error)
            }
        }
    }

    // MARK: - stdout ayrıştırma

    private func ingest(_ data: Data) {
        var completeLines: [Data] = []

        lock.lock()
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            if !lineData.isEmpty { completeLines.append(Data(lineData)) }
        }
        lock.unlock()

        for lineData in completeLines {
            handleLine(lineData)
        }
    }

    private func handleLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }

        guard type == "result" else { return }

        let isError = (object["is_error"] as? Bool) ?? false
        let text = (object["result"] as? String) ?? ""

        lock.lock()
        let continuation = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()

        guard let continuation else { return }

        if isError || text.isEmpty {
            let subtype = (object["subtype"] as? String) ?? "bilinmiyor"
            continuation.resume(throwing: HandleError.badReply(subtype))
        } else {
            continuation.resume(returning: text)
        }
    }

    // MARK: - Sonlanma

    private func handleTermination(status: Int32) {
        Self.unregisterPID(process.processIdentifier)
        lock.lock()
        alive = false
        ready = false
        let failing = pending
        pending.removeAll()
        let waiters = exitWaiters
        exitWaiters.removeAll()
        lock.unlock()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        for continuation in failing { continuation.resume(throwing: HandleError.died(status)) }
        for waiter in waiters { waiter.resume() }
        Log.info(.claude, "[\(label)] süreç sonlandı (kod \(status))")
    }

    /// Süreç bitene kadar bekler.
    func waitUntilExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !alive {
                lock.unlock()
                continuation.resume()
                return
            }
            exitWaiters.append(continuation)
            lock.unlock()
        }
    }

    /// Temiz kapanış: stdin kapat, 2 sn bekle, kapanmazsa terminate.
    func shutdown() async {
        let wasAlive: Bool = locked {
            let was = alive
            ready = false
            return was
        }

        guard wasAlive else { return }

        try? stdinPipe.fileHandleForWriting.close()

        let closed = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { [weak self] in
                await self?.waitUntilExit()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !closed, process.isRunning {
            Log.warn(.claude, "[\(label)] 2 sn içinde kapanmadı, terminate ediliyor")
            process.terminate()
            try? await Task.sleep(for: .milliseconds(300))
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}
