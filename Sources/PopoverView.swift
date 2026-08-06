import SwiftUI

/// Liquid Glass popover, Apple-Music-styled: the album art (blurred + saturated) fills
/// the backdrop and tints the whole panel; controls float above as Liquid Glass.
@available(macOS 26.0, *)
struct PopoverView: View {
    @ObservedObject var vm: EQViewModel
    @ObservedObject private var loc = Loc.shared   // re-render on language switch
    @State private var showSettings = false
    @State private var onboardingPage = 0
    @AppStorage(StatusBarController.onboardingKey) private var hasSeenOnboarding = false

    private var accent: Color { vm.accent }
    private let panelWidth: CGFloat = 336

    var body: some View {
        ZStack {
            backdrop.frame(maxWidth: .infinity, maxHeight: .infinity)
            if hasSeenOnboarding { content } else { onboarding }
        }
        .frame(width: panelWidth)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .animation(.smooth(duration: 0.5), value: vm.presetName)
        .animation(.smooth(duration: 0.4), value: vm.artworkAccent)
        .animation(.smooth(duration: 0.3), value: vm.userWantsEQ)
    }

    // MARK: First launch

    private var onboarding: some View {
        VStack(spacing: 18) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .bold))
                    Text("Eqlume")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                Spacer()
                Text("\(onboardingPage + 1) / 3")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer(minLength: 2)

            ZStack {
                Circle().fill(accent.opacity(0.16)).frame(width: 88, height: 88)
                Circle().stroke(accent.opacity(0.30), lineWidth: 1).frame(width: 68, height: 68)
                Image(systemName: onboardingIcon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: accent.opacity(0.8), radius: 12)
            }

            VStack(spacing: 8) {
                Text(onboardingTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(onboardingBody)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 274)
            }

            Spacer(minLength: 2)

            Button(action: advanceOnboarding) {
                HStack(spacing: 7) {
                    Text(onboardingPage == 2 ? loc.t("Start listening", "Dinlemeye başla") : loc.t("Continue", "Devam"))
                    Image(systemName: onboardingPage == 2 ? "checkmark" : "arrow.right")
                }
                .font(.system(size: 12, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
            }
            .buttonStyle(.glassProminent)
            .tint(accent)
        }
        .padding(18)
        .frame(width: panelWidth, height: 350)
    }

    private var onboardingIcon: String {
        switch onboardingPage {
        case 0: return "waveform.path.ecg"
        case 1: return "headphones"
        default: return "sparkles"
        }
    }

    private var onboardingTitle: String {
        switch onboardingPage {
        case 0: return loc.t("Your music, tuned live", "Müziğin, anında ayarlı")
        case 1: return loc.t("Private by design", "Gizlilik odaklı")
        default: return loc.t("Set it and forget it", "Aç ve müziğe bırak")
        }
    }

    private var onboardingBody: String {
        switch onboardingPage {
        case 0:
            return loc.t("Eqlume shapes system audio in real time and follows the character of every track.",
                         "Eqlume sistem sesini gerçek zamanlı biçimlendirir ve her parçanın karakterini takip eder.")
        case 1:
            return loc.t("Audio stays on this Mac. Permission is used only to process sound and play it straight back.",
                         "Ses bu Mac'te kalır. İzin yalnızca sesi işleyip doğrudan geri çalmak için kullanılır.")
        default:
            return loc.t("Automatic mode reads now-playing details and chooses a fitting profile. You remain in control.",
                         "Otomatik mod çalan parça bilgisini okuyup uygun profili seçer. Kontrol her zaman sende kalır.")
        }
    }

    private func advanceOnboarding() {
        if onboardingPage < 2 {
            withAnimation(.smooth(duration: 0.3)) { onboardingPage += 1 }
        } else {
            withAnimation(.smooth(duration: 0.35)) { hasSeenOnboarding = true }
        }
    }

    // MARK: Backdrop — bright/colorful so the Liquid Glass actually refracts (Apple-Music style)

    private var backdrop: some View {
        ZStack {
            if let art = vm.artwork {
                // Blurred album art — colorful bed for the glass to refract.
                Image(nsImage: art).resizable().scaledToFill()
                    .blur(radius: 68).saturation(1.18).scaleEffect(1.2)
                Color.black.opacity(0.46)   // richer blacks keep the controls crisp
            } else {
                // Vibrant accent gradient when there's no art.
                LinearGradient(colors: [accent, accent.opacity(0.45), Theme.bgBottom],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            // Corner glow adds depth
            RadialGradient(colors: [accent.opacity(0.34), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 300)
            RadialGradient(colors: [.white.opacity(0.13), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 210)
            // Localized scrims for legible header/footer text; mid stays brighter for glass.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.28), location: 0.0),
                .init(color: .black.opacity(0.10), location: 0.25),
                .init(color: .black.opacity(0.18), location: 0.70),
                .init(color: .black.opacity(0.62), location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 12) {
            header
            nowPlaying
            curvePanel
            autoToggle
            chips
            footer
            if showSettings { settingsPanel }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 13)
        // Hard-pin the content column to exactly the panel width so a child with a large
        // ideal width (the horizontal chips ScrollView reports its full content width)
        // can't expand the column and get center-clipped on both sides.
        .frame(width: panelWidth)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(.white.opacity(0.10))
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 29, height: 29)
            .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 0.7))
            Text("Eqlume")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            statusPill
            Spacer(minLength: 6)
            powerButton
        }
    }

    /// Clear ON / BYPASS / OFF state indicator next to the title.
    private var statusPill: some View {
        let (label, color): (String, Color) = {
            if !vm.userWantsEQ { return (loc.t("Off", "Kapalı"), .white.opacity(0.4)) }
            if vm.isRunning { return (loc.t("On", "Açık"), Color(hex: 0x35C759)) }   // green = processing
            return (loc.t("Bypass", "Bypass"), Color(hex: 0xFFB02E))                 // amber = on but not this device
        }()
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.white.opacity(0.12)))
    }

    /// Power toggle: filled/glowing when ON, hollow/dim when OFF — unmistakable state.
    @ViewBuilder private var powerButton: some View {
        let btn = Button(action: vm.onToggleEQ) {
            Image(systemName: "power")
                .font(.system(size: 14, weight: .bold))
                .frame(width: 32, height: 32)
        }
        .buttonBorderShape(.circle)

        if vm.userWantsEQ {
            btn.buttonStyle(.glassProminent).tint(accent)
                .shadow(color: accent.opacity(0.6), radius: 7)
        } else {
            btn.buttonStyle(.glass).tint(.white.opacity(0.5))
        }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            artworkThumb
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.nowTitle.isEmpty ? loc.t("Not playing", "Çalmıyor") : vm.nowTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                Text(vm.nowArtist.isEmpty ? " " : vm.nowArtist)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                if !vm.nowTitle.isEmpty {
                    HStack(spacing: 5) {
                        Circle().fill(vm.genreAccent).frame(width: 5, height: 5)
                            .shadow(color: vm.genreAccent.opacity(0.8), radius: 3)
                        Text(vm.presetDisplayName)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1).truncationMode(.tail)
                        if !vm.detectionSource.isEmpty {
                            Text("· \(vm.detectionSource)")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            transportControls
        }
    }

    // MARK: Transport (routes to whatever player is currently playing)

    private var transportControls: some View {
        HStack(spacing: 0) {
            transportButton("backward.fill", size: 14, action: vm.onPrevious)
            transportButton("playpause.fill", size: 18, action: vm.onPlayPause)
            transportButton("forward.fill", size: 14, action: vm.onNext)
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 32)
                .contentShape(Rectangle())
                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }

    private var artworkThumb: some View {
        Group {
            if let art = vm.artwork {
                Image(nsImage: art).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [accent.opacity(0.9), accent.opacity(0.4)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
    }

    // MARK: EQ curve + spectrum (clear glass panel over the art)

    private var curvePanel: some View {
        VStack(spacing: 8) {
            HStack {
                Label(loc.t("Sound profile", "Ses profili"), systemImage: "waveform.path.ecg")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(vm.isRunning ? accent : .white.opacity(0.35)).frame(width: 5, height: 5)
                    Text(statusWord)
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(vm.isRunning ? accent : .white.opacity(0.45))
                }
            }
            Canvas { ctx, size in
                drawGrid(ctx, size)
                drawSpectrum(ctx, size)
                drawCurve(ctx, size)
            }
            .frame(height: 70)
            HStack {
                Text("20 HZ").font(.system(size: 7.5, weight: .medium)).tracking(0.5).foregroundStyle(.white.opacity(0.34))
                Spacer()
                Text("1 KHZ").font(.system(size: 7.5, weight: .medium)).tracking(0.5).foregroundStyle(.white.opacity(0.28))
                Spacer()
                Text("20 KHZ").font(.system(size: 7.5, weight: .medium)).tracking(0.5).foregroundStyle(.white.opacity(0.34))
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(.black.opacity(0.16)))
        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(.white.opacity(0.09), lineWidth: 0.7))
    }

    private var statusWord: String {
        if vm.bypassReason != nil { return "BYPASS" }
        return vm.isRunning ? loc.t("ACTIVE", "AKTİF") : loc.t("READY", "HAZIR")
    }

    private func drawSpectrum(_ ctx: GraphicsContext, _ size: CGSize) {
        guard !vm.spectrum.isEmpty else { return }
        let n = vm.spectrum.count
        let bw = size.width / CGFloat(n)
        for (i, lvl) in vm.spectrum.enumerated() {
            let bh = CGFloat(lvl) * size.height
            guard bh > 0.5 else { continue }
            let rect = CGRect(x: CGFloat(i) * bw + bw * 0.14, y: size.height - bh,
                              width: bw * 0.72, height: bh)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.4), with: .linearGradient(
                Gradient(colors: [accent.opacity(0.20), .white.opacity(0.06)]),
                startPoint: CGPoint(x: 0, y: size.height - bh), endPoint: CGPoint(x: 0, y: size.height)))
        }
    }

    private func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height / 2))
        baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        ctx.stroke(baseline, with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))

        for fraction in [0.25, 0.5, 0.75] as [CGFloat] {
            var guide = Path()
            guide.move(to: CGPoint(x: size.width * fraction, y: 0))
            guide.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
            ctx.stroke(guide, with: .color(.white.opacity(0.045)), lineWidth: 0.5)
        }
    }

    private func drawCurve(_ ctx: GraphicsContext, _ size: CGSize) {
        guard vm.responseDB.count > 1 else { return }
        let count = vm.responseDB.count
        let dbRange: CGFloat = 15
        func point(_ i: Int) -> CGPoint {
            let x = size.width * CGFloat(i) / CGFloat(count - 1)
            let db = CGFloat(vm.responseDB[i])
            var y = size.height / 2 - (db / dbRange) * (size.height / 2 - 8)
            y = max(3, min(size.height - 3, y))
            return CGPoint(x: x, y: y)
        }
        var line = Path()
        line.move(to: point(0))
        for i in 1..<count { line.addLine(to: point(i)) }
        var fill = line
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        ctx.fill(fill, with: .linearGradient(
            Gradient(colors: [accent.opacity(0.40), accent.opacity(0.03)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
        var glow = ctx
        glow.addFilter(.shadow(color: accent.opacity(0.8), radius: 5))
        glow.stroke(line, with: .color(accent), lineWidth: 2.2)
        ctx.stroke(line, with: .color(.white.opacity(0.65)), lineWidth: 0.6)
    }

    // MARK: Auto toggle (glass capsule)

    private var autoToggle: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(vm.autoOn ? accent.opacity(0.16) : .white.opacity(0.06))
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(vm.autoOn ? accent : .white.opacity(0.55))
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc.t("Automatic Preset", "Otomatik Preset"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(vm.autoOn ? detectionShort : loc.t("off", "kapalı"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
#if APP_STORE_SCREENSHOTS
            ZStack(alignment: vm.autoOn ? .trailing : .leading) {
                Capsule().fill(vm.autoOn ? accent : .white.opacity(0.18))
                Circle().fill(.white).padding(2).shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
            .frame(width: 38, height: 22)
#else
            Toggle("", isOn: Binding(get: { vm.autoOn }, set: { _ in vm.onToggleAuto() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(accent)
                .scaleEffect(0.85)
#endif
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.10)))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 0.7))
    }

    /// Auto-toggle subtitle, composed from structured detection state and localized here
    /// (never parsed out of a pre-rendered string).
    private var detectionShort: String {
        switch vm.detectionStatus {
        case .idle:
            return ""
        case .noSource:
            return loc.t("No audio source", "Ses kaynağı yok")
        case .unreadable:
            let app = vm.detectionSourceApp.isEmpty ? "" : vm.detectionSourceApp + " — "
            return app + loc.t("track couldn't be read (Automation permission?)", "şarkı okunamadı (Otomasyon izni?)")
        case .playing:
            var s = vm.detectionSourceApp.isEmpty ? "" : "\(vm.detectionSourceApp): "
            s += vm.nowArtist.isEmpty ? vm.nowTitle : "\(vm.nowArtist) — \(vm.nowTitle)"
            if vm.detectionSourceKind == .analyzing {
                s += " · " + loc.t("analyzing…", "analiz…")
            }
            return s
        }
    }

    // MARK: Preset chips (glass capsules)

    private var chips: some View {
        // Only the natural/Harman preset is offered as a manual chip. The active preset
        // (including whatever auto picks per track) is already shown under the track title,
        // so the full 21-chip grid was redundant clutter.
        HStack(spacing: 0) {
            chip(EQPreset.natural)
            Spacer(minLength: 0)
        }
    }

    private func chip(_ preset: EQPreset) -> some View {
        // In manual mode the highlighted chip is the user's pinned pick. In auto mode it follows
        // whatever auto selected for the playing track — but when auto is on with NO source
        // (idle), nothing is highlighted, so the old manual pick doesn't linger as a fake pin.
        let active = preset.name == vm.presetName && (!vm.autoOn || vm.autoHasSource)
        let chipColor = Theme.family(forPresetName: preset.name)?.accent ?? Theme.idleAccent
        return Button { vm.onSelectPreset(preset.name) } label: {
            Text(preset.displayName)
                .font(.system(size: 10, weight: active ? .bold : .semibold))
                .foregroundStyle(active ? .black.opacity(0.88) : .white.opacity(0.9))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(
                    Capsule().fill(active ? AnyShapeStyle(chipColor.gradient) : AnyShapeStyle(.white.opacity(0.09)))
                )
                .overlay(Capsule().stroke(.white.opacity(active ? 0 : 0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "hifispeaker.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
            Text(vm.outputName).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.48))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            #if !APP_STORE
            Image(systemName: vm.spotifyConnected ? "link.circle.fill" : "link.circle")
                .font(.system(size: 11))
                .foregroundStyle(vm.spotifyConnected ? Color(hex: 0x1DB954) : .white.opacity(0.28))
            #endif
            Button { withAnimation(.smooth(duration: 0.25)) { showSettings.toggle() } } label: {
                Image(systemName: showSettings ? "chevron.down" : "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(showSettings ? accent : .white.opacity(0.55))
                    .frame(width: 27, height: 27)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
    }

    // MARK: Settings panel

    private var settingsPanel: some View {
        VStack(spacing: 1) {
            languageRow
            if vm.canOptInCurrentOutput {
                Divider().overlay(.white.opacity(0.1)).padding(.vertical, 2)
                currentOutputRow
            }
            Divider().overlay(.white.opacity(0.1)).padding(.vertical, 2)
            // Spotify OAuth pre-fetch is not part of the App Store build, so its row is hidden
            // there. Spotify itself still works via AppleScript (now-playing + transport).
            #if !APP_STORE
            settingsRow(icon: vm.spotifyConnected ? "checkmark.seal.fill" : "music.note.list",
                        title: vm.spotifyConnected ? loc.t("Spotify Connected (pre-fetch)", "Spotify Bağlı (pre-fetch)")
                                                   : loc.t("Connect with Spotify…", "Spotify ile Bağlan…"),
                        tint: vm.spotifyConnected ? Color(hex: 0x1DB954) : .white,
                        action: vm.onConnectSpotify)
            #endif
            settingsRow(icon: "lock.shield", title: loc.t("Test automation permissions", "Otomasyon izinlerini test et"), action: vm.onTestAutomation)
            settingsRow(icon: "play.rectangle", title: loc.t("Test YT Music access", "YT Music erişimini test et"), action: vm.onTestYTMusic)
            settingsRow(icon: vm.loginEnabled ? "checkmark.circle.fill" : "power",
                        title: loc.t("Launch at Login", "Açılışta Başlat"), tint: vm.loginEnabled ? accent : .white,
                        action: vm.onToggleLogin)
            Divider().overlay(.white.opacity(0.1)).padding(.vertical, 2)
            settingsRow(icon: "hand.raised", title: loc.t("Privacy Policy", "Gizlilik Politikası"), action: vm.onOpenPrivacy)
            settingsRow(icon: "doc.text", title: loc.t("Licenses & Credits", "Lisanslar ve Katkılar"), action: vm.onOpenLicenses)
            Divider().overlay(.white.opacity(0.1)).padding(.vertical, 2)
            settingsRow(icon: "xmark.circle", title: loc.t("Quit", "Çıkış"), tint: Color(hex: 0xFF6B6B), action: vm.onQuit)
        }
        .padding(7)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    /// Per-device opt-in for the current output (monitor speakers, USB DAC, …). Hidden for
    /// the built-in jack (always on) and the built-in speakers (never processed).
    private var currentOutputRow: some View {
        HStack(spacing: 9) {
            Image(systemName: vm.currentOutputAllowed ? "checkmark.circle.fill" : "hifispeaker")
                .font(.system(size: 11))
                .foregroundStyle(vm.currentOutputAllowed ? accent : .white)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc.t("EQ on this output", "Bu çıkışta EQ"))
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.95))
                Text(vm.currentOutputAllowed
                     ? loc.t("Desktop-speaker correction + genre presets", "Masa hoparlörü düzeltmesi + tür presetleri")
                     : vm.outputName)
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { vm.currentOutputAllowed },
                                     set: { _ in vm.onToggleCurrentOutput() }))
                .labelsHidden().toggleStyle(.switch).tint(accent).scaleEffect(0.8)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    /// Language selector: English (default) / Türkçe.
    private var languageRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(.white).frame(width: 16)
            Text(loc.t("Language", "Dil")).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.95))
            Spacer()
            ForEach(AppLanguage.allCases, id: \.self) { lang in
                let selected = loc.lang == lang
                Button { vm.onSetLanguage(lang) } label: {
                    Text(lang == .en ? "EN" : "TR")
                        .font(.system(size: 10, weight: selected ? .bold : .medium))
                        .foregroundStyle(selected ? .black.opacity(0.88) : .white.opacity(0.8))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(selected ? AnyShapeStyle(accent) : AnyShapeStyle(.white.opacity(0.12))))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func settingsRow(icon: String, title: String, tint: Color = .white,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint).frame(width: 16)
                Text(title).font(.system(size: 11.5)).foregroundStyle(tint.opacity(0.95))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
