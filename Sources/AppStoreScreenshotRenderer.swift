import AppKit
import SwiftUI

#if APP_STORE_SCREENSHOTS
@available(macOS 26.0, *)
@MainActor
enum AppStoreScreenshotRenderer {
    private struct Scene {
        let fileName: String
        let eyebrow: String
        let title: String
        let subtitle: String
        let preset: String
        let track: String
        let artist: String
        let accent: Color
        let spectrumSeed: Int
        let automatic: Bool
    }

    static func renderAll() {
        UserDefaults.standard.set(true, forKey: StatusBarController.onboardingKey)
        let scenes = [
            Scene(fileName: "01-follows-your-music", eyebrow: "AUTOMATIC EQ", title: "Your music, in its best light.", subtitle: "EqLume follows every track and shapes your Mac’s sound in real time.", preset: EQPreset.edm.name, track: "Neon Horizon", artist: "EqLume Sessions", accent: Color(hex: 0x6C63FF), spectrumSeed: 3, automatic: true),
            Scene(fileName: "02-see-the-sound", eyebrow: "LIVE VISUALS", title: "See what your music feels like.", subtitle: "A responsive spectrum and EQ curve make every adjustment beautifully clear.", preset: EQPreset.rock.name, track: "Midnight Drive", artist: "EqLume Sessions", accent: Color(hex: 0xFF4D8D), spectrumSeed: 7, automatic: false),
            Scene(fileName: "03-private-by-design", eyebrow: "PRIVATE BY DESIGN", title: "Your audio stays on your Mac.", subtitle: "No recording, no behavioral tracking — just native, real-time processing.", preset: EQPreset.jazz.name, track: "After Hours", artist: "EqLume Sessions", accent: Color(hex: 0x21C7A8), spectrumSeed: 11, automatic: true),
        ]

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("assets/app-store", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for scene in scenes {
            guard let png = render(scene) else { continue }
            try? png.write(to: output.appendingPathComponent("\(scene.fileName).png"), options: .atomic)
        }
        print("Rendered App Store screenshots to \(output.path)")
    }

    private static func render(_ scene: Scene) -> Data? {
        let vm = makeViewModel(scene)
        let hosting = NSHostingView(rootView: ScreenshotCanvas(scene: scene, vm: vm))
        hosting.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Liquid Glass and Canvas need a real window/render pass. Keeping this offscreen
        // yields the exact app UI without briefly flashing a capture window to the user.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(0.35)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        hosting.displayIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            window.close()
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        window.close()
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func makeViewModel(_ scene: Scene) -> EQViewModel {
        let vm = EQViewModel()
        vm.userWantsEQ = true
        vm.isRunning = true
        vm.autoOn = scene.automatic
        vm.autoHasSource = scene.automatic
        vm.nowTitle = scene.track
        vm.nowArtist = scene.artist
        vm.presetName = scene.preset
        vm.detectionSourceKind = .catalog
        vm.detectionStatus = .playing
        vm.detectionSourceApp = "Music"
        vm.artworkAccent = scene.accent
        vm.outputName = "MacBook Pro Headphones"
        vm.freqs = (0..<96).map { index in 20 * pow(1000, Double(index) / 95) }
        vm.responseDB = (0..<96).map { index in
            let x = Double(index) / 95
            return sin(x * .pi * 2.4) * 2.2 + cos(x * .pi * 5.2) * 0.8
        }
        vm.spectrum = (0..<64).map { index in
            let wave = sin(Double(index + scene.spectrumSeed) * 0.43) * 0.18
            let falloff = max(0.18, 0.92 - Double(index) / 82)
            return Float(max(0.08, min(1, falloff + wave)))
        }
        vm.artwork = artwork(accent: scene.accent)
        return vm
    }

    private static func artwork(accent: Color) -> NSImage {
        let view = ZStack {
            LinearGradient(colors: [accent, Color(hex: 0x10132D)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(.white.opacity(0.16)).frame(width: 150).blur(radius: 22).offset(x: 55, y: -45)
            Circle().fill(Color(hex: 0x24C8FF).opacity(0.24)).frame(width: 120).blur(radius: 26).offset(x: -55, y: 55)
        }.frame(width: 256, height: 256)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 256, height: 256)
        renderer.scale = 2
        return renderer.nsImage ?? NSImage(size: NSSize(width: 256, height: 256))
    }

    private struct ScreenshotCanvas: View {
        let scene: Scene
        @ObservedObject var vm: EQViewModel

        var body: some View {
            ZStack {
                Color(hex: 0x070912)
                LinearGradient(colors: [scene.accent.opacity(0.35), .clear, Color(hex: 0x12152B)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(scene.accent.opacity(0.18)).frame(width: 720).blur(radius: 100).offset(x: 500, y: -300)
                Circle().fill(Color(hex: 0x2D8CFF).opacity(0.12)).frame(width: 620).blur(radius: 120).offset(x: -560, y: 390)

                HStack(spacing: 92) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 42, height: 42)
                            Text("EqLume").font(.system(size: 26, weight: .bold, design: .rounded))
                        }
                        .padding(.bottom, 72)

                        Text(scene.eyebrow)
                            .font(.system(size: 15, weight: .bold))
                            .tracking(3.2)
                            .foregroundStyle(scene.accent)
                            .padding(.bottom, 22)
                        Text(scene.title)
                            .font(.system(size: 58, weight: .bold, design: .rounded))
                            .tracking(-1.8)
                            .lineSpacing(-3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 24)
                        Text(scene.subtitle)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineSpacing(7)
                            .frame(maxWidth: 560, alignment: .leading)
                    }
                    .frame(width: 610, alignment: .leading)

                    PopoverView(vm: vm)
                        .scaleEffect(1.42)
                        .shadow(color: .black.opacity(0.55), radius: 42, y: 24)
                        .overlay(RoundedRectangle(cornerRadius: 34).stroke(.white.opacity(0.14), lineWidth: 1.2).scaleEffect(1.42))
                        .frame(width: 500)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 92)
            }
            .frame(width: 1440, height: 900)
        }
    }
}
#endif
