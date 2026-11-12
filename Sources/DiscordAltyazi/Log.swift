// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.

import Foundation

/// Konsola zaman damgalı, kategorili log basar. Gecikme ölçümleri de buradan geçer.
enum Log {
    enum Category: String {
        case app = "APP"
        case audio = "SES"
        case stt = "STT"
        case translate = "CEVIRI"
        case claude = "CLAUDE"
        case apple = "APPLE"
        case overlay = "OVERLAY"
        case swap = "HOTSWAP"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let lock = NSLock()

    /// Konsolun yanı sıra dosyaya da yazılır — uygulama Finder'dan açıldığında
    /// stdout görünmüyor. Yol: ~/Library/Logs/DiscordAltyazi.log
    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("DiscordAltyazi.log")
    }()

    nonisolated(unsafe) private static var fileHandle: FileHandle? = {
        let path = fileURL.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: fileURL)
        // Her açılışta baştan yaz — log dosyası şişmesin.
        try? handle?.truncate(atOffset: 0)
        return handle
    }()

    static func write(_ category: Category, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] [\(category.rawValue)] \(message)"
        lock.lock()
        print(line)
        fflush(stdout)
        if let data = (line + "\n").data(using: .utf8) {
            try? fileHandle?.write(contentsOf: data)
        }
        lock.unlock()
    }

    static func info(_ c: Category, _ m: String) { write(c, m) }
    static func warn(_ c: Category, _ m: String) { write(c, "⚠️ \(m)") }
    static func error(_ c: Category, _ m: String) { write(c, "❌ \(m)") }

    /// Milisaniye cinsinden gecikme ölçümü için yardımcı.
    static func ms(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }
}
