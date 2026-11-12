// LiveCaption · © 2026 IEF Software · iefsoftware.tr
// MIT Lisansı — bkz. LICENSE.

import AppKit

/// Menü çubuğu ikonu ve menüsü.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    var onToggleCapture: (() -> Void)?
    var onToggleOverlay: (() -> Void)?
    var onSelectBackend: ((TranslatorBackend) -> Void)?
    var onSelectFontSize: ((SubtitleFontSize) -> Void)?
    var onSelectPosition: ((OverlayPosition) -> Void)?
    var onToggleFastMode: (() -> Void)?
    var onToggleMusicFilter: (() -> Void)?
    var onToggleFastRecognition: (() -> Void)?
    var onToggleSpeakerNames: (() -> Void)?
    var onSelectLanguage: ((String) -> Void)?
    var onQuit: (() -> Void)?

    /// Menü açılırken güncel backend açıklamasını sağlar ("Claude (hazır)" gibi).
    var backendDescriptionProvider: (() -> String)?

    private var item: NSStatusItem!
    private let menu = NSMenu()

    private var captureItem: NSMenuItem!
    private var overlayItem: NSMenuItem!
    private var backendInfoItem: NSMenuItem!
    private var backendMenu: NSMenu!
    private var fontMenu: NSMenu!
    private var positionMenu: NSMenu!
    private var fastModeItem: NSMenuItem!
    private var musicFilterItem: NSMenuItem!
    private var fastRecognitionItem: NSMenuItem!
    private var speakerNamesItem: NSMenuItem!
    private var languageMenu: NSMenu!
    private var languageRoot: NSMenuItem!

    private(set) var isCapturing = false

    override init() {
        super.init()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        buildMenu()
        item.menu = menu
        menu.delegate = self
    }

    // MARK: - İkon

    private func configureButton() {
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "LiveCaption")
        button.image?.isTemplate = true
        button.toolTip = "LiveCaption"
    }

    /// Durum göstergesi: yakalama açıkken dolu ikon.
    func setCapturing(_ capturing: Bool) {
        isCapturing = capturing
        guard let button = item.button else { return }
        let symbol = capturing ? "captions.bubble.fill" : "captions.bubble"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LiveCaption")
        button.image?.isTemplate = true
        button.contentTintColor = capturing ? .systemGreen : nil
        captureItem.title = capturing ? "Yakalamayı Durdur" : "Yakalamayı Başlat"
    }

    func setOverlayVisible(_ visible: Bool) {
        overlayItem.title = visible ? "Overlay'i Gizle" : "Overlay'i Göster"
    }

    // MARK: - Menü

    private func buildMenu() {
        captureItem = NSMenuItem(title: "Yakalamayı Başlat", action: #selector(toggleCapture), keyEquivalent: "t")
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        captureItem.target = self
        menu.addItem(captureItem)

        overlayItem = NSMenuItem(title: "Overlay'i Gizle", action: #selector(toggleOverlay), keyEquivalent: "h")
        overlayItem.keyEquivalentModifierMask = [.command, .shift]
        overlayItem.target = self
        menu.addItem(overlayItem)

        menu.addItem(.separator())

        // Kaynak dil — içerik açılışta asenkron doldurulur.
        languageRoot = NSMenuItem(title: "Kaynak Dil", action: nil, keyEquivalent: "")
        languageMenu = NSMenu()
        let loading = NSMenuItem(title: "Diller yükleniyor…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        languageMenu.addItem(loading)
        languageRoot.submenu = languageMenu
        menu.addItem(languageRoot)

        backendInfoItem = NSMenuItem(title: "Çeviri: —", action: nil, keyEquivalent: "")
        backendInfoItem.isEnabled = false
        menu.addItem(backendInfoItem)

        // Çeviri arka ucu
        let backendRoot = NSMenuItem(title: "Çeviri Backend'i", action: nil, keyEquivalent: "")
        backendMenu = NSMenu()
        for backend in TranslatorBackend.allCases {
            let menuItem = NSMenuItem(title: backend.displayName, action: #selector(selectBackend(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = backend.rawValue
            backendMenu.addItem(menuItem)
        }
        backendRoot.submenu = backendMenu
        menu.addItem(backendRoot)

        // Yazı boyutu
        let fontRoot = NSMenuItem(title: "Yazı Boyutu", action: nil, keyEquivalent: "")
        fontMenu = NSMenu()
        for size in SubtitleFontSize.allCases {
            let menuItem = NSMenuItem(title: size.displayName, action: #selector(selectFontSize(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = size.rawValue
            fontMenu.addItem(menuItem)
        }
        fontRoot.submenu = fontMenu
        menu.addItem(fontRoot)

        // Konum
        let positionRoot = NSMenuItem(title: "Konum", action: nil, keyEquivalent: "")
        positionMenu = NSMenu()
        for position in OverlayPosition.allCases {
            let menuItem = NSMenuItem(title: position.displayName, action: #selector(selectPosition(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = position.rawValue
            positionMenu.addItem(menuItem)
        }
        positionRoot.submenu = positionMenu
        menu.addItem(positionRoot)

        fastModeItem = NSMenuItem(title: "Hızlı Mod (Apple önce, Claude düzeltir)",
                                  action: #selector(toggleFastMode), keyEquivalent: "")
        fastModeItem.target = self
        menu.addItem(fastModeItem)

        musicFilterItem = NSMenuItem(title: "Müziği Çevirme", action: #selector(toggleMusicFilter), keyEquivalent: "")
        musicFilterItem.target = self
        menu.addItem(musicFilterItem)

        fastRecognitionItem = NSMenuItem(title: "Hızlı Tanıma (erken, biraz daha hatalı)",
                                         action: #selector(toggleFastRecognition), keyEquivalent: "")
        fastRecognitionItem.target = self
        menu.addItem(fastRecognitionItem)

        speakerNamesItem = NSMenuItem(title: "Konuşmacı Adını Göster",
                                      action: #selector(toggleSpeakerNames), keyEquivalent: "")
        speakerNamesItem.target = self
        menu.addItem(speakerNamesItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Çıkış", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshChecks()
    }

    /// Kaynak dil listesini doldurur. Kurulu olmayan modeller ⬇ ile,
    /// Apple'ın Türkçeye çeviremediği diller "· yalnız Claude" ile işaretlenir.
    func setLanguageOptions(_ options: [LanguageOption]) {
        languageMenu.removeAllItems()
        guard !options.isEmpty else {
            let empty = NSMenuItem(title: "Dil bulunamadı", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            languageMenu.addItem(empty)
            return
        }
        for option in options {
            var title = option.displayName
            if !option.isInstalled { title += " ⬇" }
            if !option.appleCanTranslate { title += " · yalnız Claude" }
            let item = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.identifier
            languageMenu.addItem(item)
        }
        refreshChecks()
    }

    /// Seçili ayarların yanına tik koy, backend durumunu tazele.
    func refreshChecks() {
        let settings = Settings.shared
        for menuItem in backendMenu.items {
            menuItem.state = (menuItem.representedObject as? String) == settings.backend.rawValue ? .on : .off
        }
        for menuItem in fontMenu.items {
            menuItem.state = (menuItem.representedObject as? String) == settings.fontSize.rawValue ? .on : .off
        }
        for menuItem in positionMenu.items {
            menuItem.state = (menuItem.representedObject as? String) == settings.position.rawValue ? .on : .off
        }
        fastModeItem.state = settings.fastMode ? .on : .off
        musicFilterItem.state = settings.musicFilter ? .on : .off
        fastRecognitionItem.state = settings.fastRecognition ? .on : .off
        speakerNamesItem.state = settings.showSpeakerNames ? .on : .off
        for item in languageMenu.items {
            item.state = (item.representedObject as? String) == settings.sourceLanguage ? .on : .off
        }
        languageRoot.title = "Kaynak Dil: \(settings.sourceDisplayName)" 
        backendInfoItem.title = "Çeviri: " + (backendDescriptionProvider?() ?? "—")
    }

    // MARK: - Aksiyonlar

    @objc private func toggleCapture() { onToggleCapture?() }
    @objc private func toggleOverlay() { onToggleOverlay?() }
    @objc private func quit() { onQuit?() }
    @objc private func toggleFastMode() { onToggleFastMode?() }
    @objc private func toggleMusicFilter() { onToggleMusicFilter?() }
    @objc private func toggleFastRecognition() { onToggleFastRecognition?() }
    @objc private func toggleSpeakerNames() { onToggleSpeakerNames?() }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        onSelectLanguage?(identifier)
    }

    @objc private func selectBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let backend = TranslatorBackend(rawValue: raw) else { return }
        onSelectBackend?(backend)
    }

    @objc private func selectFontSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let size = SubtitleFontSize(rawValue: raw) else { return }
        onSelectFontSize?(size)
    }

    @objc private func selectPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let position = OverlayPosition(rawValue: raw) else { return }
        onSelectPosition?(position)
    }
}
