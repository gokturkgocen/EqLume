#if !APP_STORE
import Accelerate
import Foundation

/// Long-term average spectrum of what actually gets played, accumulated per artist.
///
/// A development instrument, not a feature — it exists so a genre curve can be written
/// from the material's own balance instead of from judgment about what the material is
/// probably like. The `.turkishFolk` delta is currently the latter, and says so.
///
/// It measures the PRE-EQ tap (`AudioEngine` fills the analysis ring before the EQ node),
/// so what lands here is the recording, not the correction. Averaged over minutes it
/// describes the recording/mastering balance of a body of work — useful in COMPARISON
/// (this catalogue against another) rather than as an absolute truth, since there is no
/// reference curve that says what a recording ought to look like.
///
/// Compiled out of the App Store build entirely.
final class SpectrumMeasurement {
    /// 8192 rather than the UI analyzer's 2048: at 48 kHz that is 5.9 Hz per bin, which is
    /// what puts enough bins inside one ERB down at 50 Hz (where the ERB is only ~30 Hz
    /// wide) for the low end to be measurable at all.
    static let fftSize = 8192
    private let log2n: vDSP_Length = 13
    private let fftSetup: FFTSetup
    private let window: [Float]

    /// artist key → running power sum per bin + how many FFT frames went into it.
    private struct Entry {
        var power: [Double]
        var frames: Int
        var preset: String
        var titles: Set<String>
    }
    private var entries: [String: Entry] = [:]
    private var sampleRate: Double = 0
    private var writesPending = 0

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eqlume", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("spectrum-measurements.json")
    }()

    init?() {
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        fftSetup = setup
        var w = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&w, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        window = w
        load()
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    var totalFrames: Int { entries.values.reduce(0) { $0 + $1.frames } }
    var artistCount: Int { entries.count }

    /// Folds one snapshot of mono audio into the artist's running average. Splits it into
    /// 50 %-overlapped FFT frames, so a few seconds of audio contributes a few hundred.
    func accumulate(samples: [Float], rate: Double, artist: String, title: String, preset: String) {
        let n = Self.fftSize
        guard samples.count >= n, rate > 0 else { return }
        // Bins are only comparable at one sample rate; if the output device changes rate,
        // start over rather than silently averaging two different frequency axes.
        if sampleRate != rate {
            if sampleRate != 0 { entries.removeAll() }
            sampleRate = rate
        }

        let key = artist.lowercased()
        var entry = entries[key] ?? Entry(power: [Double](repeating: 0, count: n / 2),
                                          frames: 0, preset: preset, titles: [])
        entry.preset = preset
        entry.titles.insert(title)

        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var mags  = [Float](repeating: 0, count: n / 2)
        var windowed = [Float](repeating: 0, count: n)

        var start = 0
        while start + n <= samples.count {
            samples.withUnsafeBufferPointer { src in
                vDSP_vmul(src.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(n))
            }
            windowed.withUnsafeBufferPointer { wbuf in
                realp.withUnsafeMutableBufferPointer { rp in
                    imagp.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        wbuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cbuf in
                            vDSP_ctoz(cbuf, 2, &split, 1, vDSP_Length(n / 2))
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
                    }
                }
            }
            // Power, not magnitude: averaging power is what makes the mean meaningful.
            for k in 0..<(n / 2) {
                let m = Double(mags[k])
                entry.power[k] += m * m
            }
            entry.frames += 1
            start += n / 2
        }

        entries[key] = entry
        writesPending += 1
        if writesPending >= 20 { save() }
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var sampleRate: Double
        var fftSize: Int
        var artists: [String: Artist]
        struct Artist: Codable {
            var frames: Int
            var preset: String
            var titles: [String]
            /// Mean power per FFT bin, in dB. Absolute level is meaningless (it depends on
            /// playback volume); only the SHAPE, and shapes compared against each other, are.
            var meanDB: [Float]
        }
    }

    func save() {
        writesPending = 0
        guard !entries.isEmpty else { return }
        var artists: [String: Stored.Artist] = [:]
        for (key, e) in entries where e.frames > 0 {
            let meanDB = e.power.map { Float(10 * log10($0 / Double(e.frames) + 1e-20)) }
            artists[key] = .init(frames: e.frames, preset: e.preset,
                                 titles: Array(e.titles).sorted(), meanDB: meanDB)
        }
        let stored = Stored(sampleRate: sampleRate, fftSize: Self.fftSize, artists: artists)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(stored) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Restores previous sessions so a measurement can span days of normal listening.
    /// dB is converted back to a power sum using the stored frame count.
    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.fftSize == Self.fftSize else { return }
        sampleRate = stored.sampleRate
        for (key, a) in stored.artists where a.frames > 0 {
            let power = a.meanDB.map { pow(10.0, Double($0) / 10.0) * Double(a.frames) }
            entries[key] = Entry(power: power, frames: a.frames,
                                 preset: a.preset, titles: Set(a.titles))
        }
    }
}
#endif
