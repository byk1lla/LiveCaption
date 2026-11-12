// DiscordAltyazi · © 2026 IEF Software · iefsoftware.tr · Tüm hakları saklıdır.
// Özel mülk yazılım. Bu bildirim kopya ve türevlerde korunur — bkz. LICENSE.

import AppKit

/// Odak çalmayan, tıklamaları geçiren, tüm masaüstlerinde görünen altyazı paneli.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Ekranın altındaki (veya üstündeki) şeffaf altyazı bandını yönetir.
@MainActor
final class OverlayController {

    private let panel: OverlayPanel
    private let container = NSView()
    private let stack = NSStackView()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let interimLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    /// Son gösterilen Türkçe cümleler (en fazla 3). Her satırın kimliği var ki
    /// hızlı hattın bastığı satır, Claude çevirisi gelince yerinde düzeltilebilsin.
    private var lines: [(id: UInt64, speaker: String?, text: String)] = []
    private let maxLines = 3

    private var fadeTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    /// Sessizlik sonrası solma süresi.
    private let fadeAfter: Double = 6.0

    private var isHidden = false

    init() {
        panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.worksWhenModal = true

        setupViews()
        applySettings()
    }

    // MARK: - Kurulum

    private func setupViews() {
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.cornerCurve = .continuous

        for label in [subtitleLabel, interimLabel, statusLabel] {
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.alignment = .center
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.cell?.wraps = true
            label.cell?.truncatesLastVisibleLine = true
        }

        subtitleLabel.textColor = .white
        interimLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        statusLabel.textColor = NSColor.systemYellow

        statusLabel.isHidden = true
        interimLabel.isHidden = true

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(subtitleLabel)
        stack.addArrangedSubview(interimLabel)

        container.addSubview(stack)
        panel.contentView = container

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])
    }

    // MARK: - Ayarlar

    /// Yazı boyutu / konum ayarlarını uygular ve pencereyi yeniden konumlandırır.
    func applySettings() {
        let size = Settings.shared.fontSize
        subtitleLabel.font = .systemFont(ofSize: size.primary, weight: .semibold)
        interimLabel.font = .systemFont(ofSize: size.secondary, weight: .regular)
        statusLabel.font = .systemFont(ofSize: size.secondary, weight: .medium)
        layoutPanel()
    }

    /// Pencere genişliğini/konumunu ekrana göre hesaplar.
    private func layoutPanel() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = (visible.width * 0.70).rounded()

        // Etiket genişliğini sabitle ki yükseklik doğru hesaplansın.
        let inner = width - 44
        subtitleLabel.preferredMaxLayoutWidth = inner
        interimLabel.preferredMaxLayoutWidth = inner
        statusLabel.preferredMaxLayoutWidth = inner

        container.layoutSubtreeIfNeeded()
        let height = max(stack.fittingSize.height + 28, 56)

        let x = visible.minX + (visible.width - width) / 2
        let y: CGFloat
        switch Settings.shared.position {
        case .bottom: y = visible.minY + 70
        case .top:    y = visible.maxY - height - 50
        }
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    // MARK: - Görünürlük

    func show() {
        isHidden = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        layoutPanel()
        scheduleFade()
    }

    func hide() {
        isHidden = true
        panel.orderOut(nil)
    }

    func toggle() {
        if isHidden { show() } else { hide() }
    }

    var visible: Bool { !isHidden }

    // MARK: - İçerik

    /// Kesinleşmiş Türkçe cümleyi ekler; eskiler yukarı kayar.
    func appendLine(id: UInt64, speaker: String?, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        lines.append((id, speaker, clean))
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        renderLines()
        interimLabel.stringValue = ""
        interimLabel.isHidden = true
        wake()
    }

    /// Hızlı hattın bastığı satırı daha iyi çeviriyle değiştirir.
    /// Satır ekrandan kaymışsa sessizce yok sayılır.
    func refineLine(id: UInt64, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = lines.firstIndex(where: { $0.id == id }) else { return }
        guard lines[index].text != clean else { return }
        lines[index].text = clean
        renderLines()
        wake()
    }

    /// Geçici (volatile) İngilizce metni soluk alt satırda gösterir.
    func setInterim(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        interimLabel.stringValue = String(clean.suffix(180))
        interimLabel.isHidden = clean.isEmpty
        layoutPanel()
        wake()
    }

    /// Kalıcı durum metni (izin uyarısı, model indirme). nil = temizle.
    func setStatus(_ text: String?) {
        noticeTask?.cancel()
        if let text, !text.isEmpty {
            statusLabel.stringValue = text
            statusLabel.isHidden = false
        } else {
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
        }
        layoutPanel()
        wake()
    }

    /// Kısa süreli uyarı (3 sn sonra kaybolur).
    func flashNotice(_ text: String) {
        setStatus(text)
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.setStatus(nil)
        }
    }

    func clear() {
        lines.removeAll()
        subtitleLabel.attributedStringValue = NSAttributedString(string: "")
        interimLabel.stringValue = ""
        interimLabel.isHidden = true
        layoutPanel()
    }

    /// Son satır parlak, önceki satırlar soluk.
    private func renderLines() {
        let result = NSMutableAttributedString()
        let size = Settings.shared.fontSize

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2

        for (index, entry) in lines.enumerated() {
            let isLast = index == lines.count - 1
            let alpha: CGFloat = isLast ? 1.0 : (index == lines.count - 2 ? 0.55 : 0.32)
            let fontSize = isLast ? size.primary : size.primary * 0.86
            if index > 0 { result.append(NSAttributedString(string: "\n")) }

            // Konuşmacı adı varsa, altyazıdan ayrışsın diye renkli ve ince yazılır.
            if Settings.shared.showSpeakerNames, let speaker = entry.speaker, !speaker.isEmpty {
                let nameAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize * 0.92, weight: .bold),
                    .foregroundColor: NSColor.systemTeal.withAlphaComponent(alpha),
                    .paragraphStyle: paragraph
                ]
                result.append(NSAttributedString(string: "\(speaker): ", attributes: nameAttributes))
            }

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: isLast ? .semibold : .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(alpha),
                .paragraphStyle: paragraph
            ]
            result.append(NSAttributedString(string: entry.text, attributes: attributes))
        }
        subtitleLabel.attributedStringValue = result
        layoutPanel()
    }

    // MARK: - Solma

    /// İçerik geldiğinde paneli tekrar görünür yap ve solma sayacını sıfırla.
    private func wake() {
        guard !isHidden else { return }
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        scheduleFade()
    }

    private func scheduleFade() {
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.fadeAfter ?? 6))
            guard let self, !Task.isCancelled, !self.isHidden else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 1.2
                self.panel.animator().alphaValue = 0
            } completionHandler: {
                // AppKit bu geri çağrıyı ana iş parçacığında yapıyor.
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.lines.removeAll()
                    self.subtitleLabel.attributedStringValue = NSAttributedString(string: "")
                    self.interimLabel.stringValue = ""
                    self.interimLabel.isHidden = true
                }
            }
        }
    }
}
