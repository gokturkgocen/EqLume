import Cocoa
import ServiceManagement
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    static let onboardingKey = "Eqlume.hasSeenOnboarding"
    private let statusItem: NSStatusItem
    private let audio = AudioEngine()
    private let loginItem = SMAppService.mainApp
    private lazy var autoSelector = AutoPresetSelector(audio: audio)

    private let vm = EQViewModel()
    private var panel: NSPanel!
    private var hostingView: NSHostingView<PopoverView>!
    private var clickMonitor: Any?
    private let spectrum = SpectrumAnalyzer()
    private var displayTimer: Timer?
    private var lastCurveKey: String = ""
    private var lastLoadedArtURL: String?

    private let presetDefaultsKey = "Eqlume.activePresetName"
    private let autoDefaultsKey   = "Eqlume.autoEnabled"

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        wireActions()
        buildPanel()

        restoreActivePreset()
        audio.onStateChange = { [weak self] in self?.syncVM() }
        autoSelector.onStatusChange = { [weak self] in self?.syncVM() }
        if UserDefaults.standard.bool(forKey: autoDefaultsKey) {
            autoSelector.enabled = true
        }
        vm.freqs = FrequencyResponse.frequencyAxis(points: 160)
        recomputeCurve()
        syncVM()
    }

#if SANDBOX_PROBE
    /// One-shot diagnostic used only by `./build.sh sandbox-probe`. It never ships in
    /// development or App Store binaries and leaves the installed app untouched.
    func runSandboxProbe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.audio.setEnabled(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let result = self.audio.isRunning ? "PASS" : "FAIL"
                let detail = self.audio.lastError ?? self.audio.bypassReason ?? "none"
                print("EQLUME_SANDBOX_PROBE=\(result) detail=\(detail)")
                self.audio.setEnabled(false)
                NSApplication.shared.terminate(nil)
            }
        }
    }
#endif

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "EqLume")
        button.image?.isTemplate = true
        button.action = #selector(togglePanel)
        button.target = self
    }

    private func wireActions() {
        vm.onToggleEQ      = { [weak self] in self?.toggleEnabled() }
        vm.onToggleAuto    = { [weak self] in self?.toggleAuto() }
        vm.onSelectPreset  = { [weak self] name in self?.selectPreset(name) }
        vm.onPrevious      = { [weak self] in self?.transport(.previous) }
        vm.onPlayPause     = { [weak self] in self?.transport(.playPause) }
        vm.onNext          = { [weak self] in self?.transport(.next) }
        #if !APP_STORE
        vm.onConnectSpotify = { [weak self] in self?.spotifyMenu() }
        #endif
        vm.onTestAutomation = { [weak self] in self?.testPermissions() }
        vm.onTestYTMusic    = { [weak self] in self?.testYouTubeMusic() }
        vm.onToggleLogin    = { [weak self] in self?.toggleLoginItem() }
        vm.onSetLanguage    = { [weak self] lang in self?.setLanguage(lang) }
        vm.onToggleCurrentOutput = { [weak self] in
            guard let self else { return }
            self.audio.setCurrentOutputAllowed(!self.audio.currentOutputAllowed)
            self.syncVM()
        }
        vm.onOpenPrivacy    = { Self.openProjectPage("PRIVACY.md") }
        vm.onOpenLicenses   = { Self.openProjectPage("THIRD-PARTY.md") }
        vm.onQuit           = { NSApplication.shared.terminate(nil) }
    }

    private static func openProjectPage(_ path: String) {
        guard let url = URL(string: "https://github.com/gokturkgocen/EqLume/blob/main/\(path)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func setLanguage(_ lang: AppLanguage) {
        Loc.shared.setLanguage(lang)   // @Published → the observing popover re-renders in the new language
        syncVM()
    }

    /// Routes a transport press to whatever supported player is currently playing.
    private func transport(_ action: PlaybackController.Action) {
        Task { await PlaybackController.perform(action) }
    }

    // MARK: Floating panel (precise positioning under the menu-bar item)

    private func buildPanel() {
        // HARD width via Auto Layout: a width constraint is not a "proposal" SwiftUI can
        // ignore (unlike .frame on a raw NSHostingView, which auto-sizes wider and gets
        // clipped). Pinning the hosting view to the panel width keeps long text truncating
        // instead of overflowing.
        let hv = NSHostingView(rootView: PopoverView(vm: vm))
        hv.translatesAutoresizingMaskIntoConstraints = false
        hostingView = hv

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 420))
        container.addSubview(hv)
        // Pin ONLY leading+top+width. NOT trailing/bottom — pinning both edges to a
        // possibly-wider container would force the hosting view to stretch and break the
        // panel width (the bug that made content overflow). With leading+width only, the
        // hosting view and container stay in lockstep.
        NSLayoutConstraint.activate([
            hv.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            hv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hv.topAnchor.constraint(equalTo: container.topAnchor),
            container.trailingAnchor.constraint(equalTo: hv.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: hv.bottomAnchor),
        ])

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 420),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.contentView = container
        p.delegate = self
        panel = p
    }

    @objc private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    static let panelWidth: CGFloat = 336

    func showPanel() {
        syncVM()
        guard let button = statusItem.button, let bw = button.window else { return }

        // Measure content height with the width hard-pinned to the panel width.
        hostingView.layoutSubtreeIfNeeded()
        let contentH = max(hostingView.fittingSize.height, 1)
        let screenH = (bw.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let panelH = min(contentH, screenH - 24)
        panel.setContentSize(NSSize(width: Self.panelWidth, height: panelH))

        let inWindow = button.convert(button.bounds, to: nil)
        let onScreen = bw.convertToScreen(inWindow)
        var x = onScreen.maxX - Self.panelWidth
        var y = onScreen.minY - panelH - 6
        if let screen = bw.screen ?? NSScreen.main {
            let vis = screen.visibleFrame
            x = min(max(vis.minX + 8, x), vis.maxX - Self.panelWidth - 8)
            if y < vis.minY + 8 { y = vis.minY + 8 }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panelTopY = y + panelH
        panel.makeKeyAndOrderFront(nil)

        startDisplayTimer()
        installClickMonitor()
    }

    private var panelTopY: CGFloat = 0

    /// Re-fit when content height changes (e.g. settings expands), keeping the top pinned
    /// under the menu bar. Called from the display timer while the panel is open.
    private func syncPanelSize() {
        guard panel.isVisible, panelTopY > 0 else { return }
        let contentH = max(hostingView.fittingSize.height, 1)
        let screenH = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let panelH = min(contentH, screenH - 24)
        if abs(panelH - panel.frame.height) > 0.5 {
            panel.setContentSize(NSSize(width: Self.panelWidth, height: panelH))
            panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: panelTopY - panelH))
        }
    }

    private func hidePanel() {
        panel.orderOut(nil)
        stopDisplayTimer()
        removeClickMonitor()
    }

    func windowDidResignKey(_ notification: Notification) {
        hidePanel()
    }

    /// Dismiss when the user clicks outside the panel (in another app or the desktop).
    private func installClickMonitor() {
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    // MARK: Live spectrum

    private func startDisplayTimer() {
        stopDisplayTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickSpectrum() }
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
        spectrum?.reset()
    }

    private func tickSpectrum() {
        guard panel.isVisible else { return }
        syncPanelSize()
        if audio.isRunning,
           let (samples, rate) = audio.snapshotAnalysisAudio(seconds: 0.06),
           let analyzer = spectrum {
            vm.spectrum = analyzer.process(samples: samples, sampleRate: rate)
        } else if !vm.spectrum.isEmpty {
            // Decay to flat when nothing is playing / EQ bypassed.
            vm.spectrum = vm.spectrum.map { $0 * 0.8 }
            if (vm.spectrum.max() ?? 0) < 0.01 { vm.spectrum = [] }
        }
    }

    // MARK: Actions

    private func toggleEnabled() {
        audio.setEnabled(!audio.userWantsEQ)
        syncVM()
    }

    private func selectPreset(_ name: String) {
        guard let preset = EQPreset.builtIn.first(where: { $0.name == name }) else { return }
        if autoSelector.enabled {
            autoSelector.enabled = false
            UserDefaults.standard.set(false, forKey: autoDefaultsKey)
        }
        audio.activePreset = preset
        UserDefaults.standard.set(name, forKey: presetDefaultsKey)
        syncVM()
    }

    private func toggleAuto() {
        autoSelector.enabled.toggle()
        UserDefaults.standard.set(autoSelector.enabled, forKey: autoDefaultsKey)
        syncVM()
    }

    private func toggleLoginItem() {
        do {
            if loginItem.status == .enabled { try loginItem.unregister() }
            else { try loginItem.register() }
        } catch {
            presentAlert(title: Loc.shared.t("Could not update login item", "Açılışta başlatma ayarı güncellenemedi"),
                         body: error.localizedDescription)
        }
        syncVM()
    }

    // MARK: State sync → view model

    private func restoreActivePreset() {
        let savedName = UserDefaults.standard.string(forKey: presetDefaultsKey) ?? EQPreset.flat.name
        if let preset = EQPreset.builtIn.first(where: { $0.name == savedName }) {
            audio.activePreset = preset
        }
    }

    private func recomputeCurve() {
        // Draw the RESOLVED preset: the curve must show the baseline actually in use for the
        // current output (Chu II correction on the jack, genre delta only on other devices).
        let preset = audio.resolvedPreset
        vm.responseDB = FrequencyResponse.responseDB(
            bands: preset.bands, globalGainDB: preset.globalGainDB,
            sampleRate: 48000, freqs: vm.freqs)
        lastCurveKey = curveKey
    }

    /// Cache key for the drawn curve. Includes the profile because the same preset name
    /// resolves to a different curve on a different output device.
    private var curveKey: String {
        "\(audio.activePreset.name)|\(audio.activeProfile)"
    }

    private func syncVM() {
        vm.userWantsEQ = audio.userWantsEQ
        vm.isRunning = audio.isRunning
        vm.bypassReason = audio.bypassReason
        vm.autoOn = autoSelector.enabled
        // Structured detection state (no string parsing). "Has a live source" = auto is on
        // and a track actually resolved; drives whether chips show a pinned pick.
        vm.autoHasSource = autoSelector.enabled && autoSelector.lastStatus == .playing
        vm.detectionStatus   = autoSelector.enabled ? autoSelector.lastStatus : .idle
        vm.detectionSourceApp = autoSelector.lastSourceApp ?? ""
        vm.detectionSourceKind = autoSelector.enabled ? autoSelector.lastSourceKind : nil
        vm.nowArtist = autoSelector.enabled ? (autoSelector.lastArtist ?? "") : ""
        vm.nowTitle  = autoSelector.enabled ? (autoSelector.lastTitle ?? "") : ""
        #if !APP_STORE
        vm.genreLabelOverride = autoSelector.enabled ? autoSelector.lastGenreLabelOverride : nil
        #endif
        vm.presetName = audio.activePreset.name
        vm.outputName = audio.outputDeviceName
        vm.canOptInCurrentOutput = audio.currentOutputSupportsOptIn
        vm.currentOutputAllowed = audio.currentOutputAllowed
        vm.usingSpeakerProfile = audio.isRunning && audio.activeProfile == .desktopSpeakers
        #if !APP_STORE
        vm.spotifyConnected = autoSelector.spotifyAuth.isConnected
        #endif
        vm.loginEnabled = (loginItem.status == .enabled)

        if lastCurveKey != curveKey {
            recomputeCurve()
        }
        loadArtworkIfChanged()
        configureButtonState()
    }

    private func loadArtworkIfChanged() {
        let url = autoSelector.lastArtworkURL
        guard url != lastLoadedArtURL else { return }
        lastLoadedArtURL = url
        guard let url else { vm.artwork = nil; vm.artworkAccent = nil; return }
        Task { [weak self] in
            guard let data = await ArtworkLoader.loadData(url) else { return }
            guard let self, self.autoSelector.lastArtworkURL == url, let img = NSImage(data: data) else { return }
            self.vm.artwork = img
            self.vm.artworkAccent = ArtworkLoader.vibrantColor(from: img)
        }
    }

    private func configureButtonState() {
        guard let button = statusItem.button else { return }
        let symbol = audio.isRunning ? "waveform.path.ecg" : "waveform"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "EqLume")
        button.image?.isTemplate = true
    }

    private func presentAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }

    // MARK: Diagnostics / Spotify (unchanged behavior, invoked from popover menu)

    private func testPermissions() {
        let apps: [(String, String)] = [
            ("Spotify",     #"tell application id "com.spotify.client" to if it is running then return name of current track"#),
            ("Apple Music", #"tell application id "com.apple.Music"    to if it is running then return name of current track"#),
            ("Chrome",      #"tell application id "com.google.Chrome"  to if it is running then if (count of windows) > 0 then return URL of active tab of front window"#),
            ("Safari",      #"tell application "Safari"                to if it is running then if (count of windows) > 0 then return URL of current tab of front window"#),
            ("Arc",         #"tell application id "company.thebrowser.Browser" to if it is running then if (count of windows) > 0 then return URL of active tab of front window"#),
            ("Brave",       #"tell application id "com.brave.Browser"  to if it is running then if (count of windows) > 0 then return URL of active tab of front window"#),
            ("Edge",        #"tell application id "com.microsoft.edgemac" to if it is running then if (count of windows) > 0 then return URL of active tab of front window"#),
        ]
        Task { @MainActor in
            let loc = Loc.shared
            var report = loc.t("Each line is a source. ✓ = allowed, ⚠ = not allowed, • = closed/absent\n\n",
                               "Her satır bir kaynak. ✓ = izinli, ⚠ = izin yok, • = kapalı/yok\n\n")
            for (name, script) in apps {
                switch await AppleScriptRunner.run(script) {
                case .success(let s):      report += "✓ \(name): \(s.isEmpty ? loc.t("(not playing)", "(çalmıyor)") : String(s.prefix(50)))\n"
                case .permissionDenied:    report += "⚠ \(name): " + loc.t("automation permission DENIED", "otomasyon izni REDDEDİLDİ") + "\n"
                case .appNotRunning:       report += "• \(name): " + loc.t("not installed or not running", "yüklü değil veya çalışmıyor") + "\n"
                case .otherError(let c, let m): report += "✗ \(name): " + loc.t("error", "hata") + " \(c) — \(m.prefix(60))\n"
                }
            }
            report += loc.t("\nIf you see ⚠: System Settings → Privacy & Security → Automation → EqLume",
                            "\n⚠ varsa: Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon → EqLume")
            let alert = NSAlert()
            alert.messageText = loc.t("Automation access status", "Otomasyon erişim durumu")
            alert.informativeText = report
            alert.addButton(withTitle: loc.t("OK", "Tamam"))
            alert.addButton(withTitle: loc.t("Open Settings", "Ayarları Aç"))
            if alert.runModal() == .alertSecondButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func testYouTubeMusic() {
        Task { @MainActor in
            let loc = Loc.shared
            var report = loc.t("Each line is a browser. ✓ = reading, ⚠ = setting missing\n\n",
                               "Her satır bir tarayıcı. ✓ = okuyor, ⚠ = ayar eksik\n\n")
            for browser in [YouTubeMusicService.BrowserKind.chrome, .arc, .brave, .edge, .safari] {
                report += "\(browser.appName): \(await YouTubeMusicService.diagnose(browser: browser))\n"
            }
            report += loc.t("\nIf you see ⚠, in the browser:\n", "\nEğer ⚠ görüyorsan tarayıcıda:\n")
            report += "  • Chrome/Brave/Edge/Arc: View → Developer → 'Allow JavaScript from Apple Events'\n"
            report += "  • Safari: Settings → Advanced → 'Show Develop menu' → Develop → " + loc.t("same", "aynısı") + "\n"
            let alert = NSAlert()
            alert.messageText = loc.t("YouTube Music access status", "YouTube Music erişim durumu")
            alert.informativeText = report
            alert.runModal()
        }
    }

    // MARK: Spotify OAuth connect flow — non-App-Store builds only
    // (the App Store build ships no loopback-listener / Keychain entitlements)

    #if !APP_STORE
    private func spotifyMenu() {
        let auth = autoSelector.spotifyAuth
        if auth.isConnected {
            let loc = Loc.shared
            let alert = NSAlert()
            alert.messageText = loc.t("Spotify connection", "Spotify bağlantısı")
            alert.informativeText = loc.t("EqLume is connected to your Spotify account. Pre-fetch is active.\n\nDo you want to disconnect?",
                                          "EqLume Spotify hesabına bağlı. Pre-fetch aktif.\n\nBağlantıyı kaldırmak ister misin?")
            alert.addButton(withTitle: loc.t("Stay connected", "Bağlı tut"))
            alert.addButton(withTitle: loc.t("Disconnect", "Bağlantıyı kaldır"))
            if alert.runModal() == .alertSecondButtonReturn { auth.disconnect(); syncVM() }
            return
        }
        if auth.clientID == nil || auth.clientID?.isEmpty == true { promptForClientID(); return }
        startConnectFlow()
    }

    private func promptForClientID() {
        let loc = Loc.shared
        let alert = NSAlert()
        alert.messageText = loc.t("Spotify Client ID required", "Spotify Client ID gerekli")
        alert.informativeText = loc.t("""
        Create an app in the Spotify Developer dashboard:

        1. https://developer.spotify.com/dashboard
        2. "Create app" → name: EqLume
        3. Redirect URI: \(SpotifyAuth.redirectURI)
        4. Choose the Web API → Save
        5. Copy the Client ID from Settings and paste it below
        """, """
        Spotify Developer dashboard'da bir uygulama oluştur:

        1. https://developer.spotify.com/dashboard
        2. "Create app" → ad: EqLume
        3. Redirect URI: \(SpotifyAuth.redirectURI)
        4. Web API'yi seç → Save
        5. Settings'ten Client ID'yi kopyala ve aşağıya yapıştır
        """)
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        input.placeholderString = loc.t("32-character hex Client ID", "32 karakterlik hex Client ID")
        alert.accessoryView = input
        alert.addButton(withTitle: loc.t("Continue", "Devam"))
        alert.addButton(withTitle: loc.t("Open Dashboard", "Dashboard'u Aç"))
        alert.addButton(withTitle: loc.t("Cancel", "Vazgeç"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let id = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            autoSelector.spotifyAuth.setClientID(id)
            startConnectFlow()
        case .alertSecondButtonReturn:
            if let url = URL(string: "https://developer.spotify.com/dashboard") { NSWorkspace.shared.open(url) }
        default: break
        }
    }

    private func startConnectFlow() {
        Task { @MainActor in
            do {
                try await autoSelector.spotifyAuth.connect()
                presentAlert(title: Loc.shared.t("Spotify connected ✓", "Spotify bağlandı ✓"),
                             body: Loc.shared.t("Pre-fetch active. In automatic preset mode the next track is prepared in advance.",
                                                "Pre-fetch aktif. Otomatik preset modunda sıradaki şarkı önceden hazırlanır."))
                syncVM()
            } catch {
                presentAlert(title: Loc.shared.t("Connection failed", "Bağlantı başarısız"),
                             body: error.localizedDescription)
            }
        }
    }
    #endif  // !APP_STORE
}
