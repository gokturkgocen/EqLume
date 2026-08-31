#if !APP_STORE
import Accelerate
import Foundation

/// Long-term average spectrum of what actually gets played, accumulated per artist.
///
/// A development instrument, not a feature — it exists so a genre curve can be written from
/// the material's own balance instead of from judgment about what the material is probably
/// like. It measures the PRE-EQ tap (`AudioEngine` fills the analysis ring before the EQ
/// node), so what lands here is the recording, not the correction.
///
/// ## Stored on a frequency axis, not on FFT bins
///
/// The first version accumulated power per FFT bin and threw everything away when the
/// output device changed sample rate, on the correct observation that bin *k* means a
/// different frequency at 44.1 kHz than at 48 kHz. The reasoning was right and the
/// consequence was indefensible: it destroyed ten days of measurement the moment a device
/// switched rate, and the test suite had frozen that behaviour in as if it were a feature.
///
/// Bins are an implementation detail of the FFT; hertz are not. Accumulating into a fixed
/// 1/24-octave grid in Hz makes every sample rate land on the same axis, so a rate change
/// costs nothing but a recomputed bin mapping. It also shrinks the file by an order of
/// magnitude (239 cells instead of 4096 bins) and hands `AdaptiveCorrection` exactly the
/// representation it wants, with no resampling step to get wrong.
///
/// Compiled out of the App Store build entirely.
final class SpectrumMeasurement {
    static let fftSize = 8192
    private let log2n: vDSP_Length = 13
    private let fftSetup: FFTSetup
    private let window: [Float]

    /// The shared analysis axis: 1/24 octave, 20 Hz → 20 kHz.
    static let gridPointsPerOctave = 24.0
    static let gridLow = 20.0
    static let gridHigh = 20_000.0
    static let grid: [Double] = {
        let n = Int((log2(gridHigh / gridLow) * gridPointsPerOctave).rounded())
        return (0...n).map { gridLow * pow(2.0, Double($0) / gridPointsPerOctave) }
    }()

    /// How each grid cell is filled from one sample rate's bins. Cells too narrow to hold a
    /// bin interpolate between neighbours rather than borrowing the nearest one, which would
    /// turn the low end into a staircase — and a staircase reads as resonance downstream.
    private enum CellSource {
        case bins(ClosedRange<Int>)
        case interpolate(lower: Int, upper: Int, t: Double)
    }
    private var cellSources: [CellSource] = []
    private var cellSourceRate: Double = 0

    private struct Entry {
        var power: [Double]        // one running sum per grid cell
        var frames: Int
        var preset: String
        var titles: Set<String>
    }
    private var entries: [String: Entry] = [:]
    private var writesPending = 0

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eqlume", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("spectrum-measurements.json")
    }()

    init?() {
        guard let setup = vDSP_create_fftsetup(13, FFTRadix(kFFTRadix2)) else { return nil }
        fftSetup = setup
        var w = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&w, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        window = w
        load()
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    var totalFrames: Int { entries.values.reduce(0) { $0 + $1.frames } }
    var artistCount: Int { entries.count }

    /// Folds one snapshot of mono audio into the artist's running average.
    func accumulate(samples: [Float], rate: Double, artist: String, title: String, preset: String) {
        let n = Self.fftSize
        guard samples.count >= n, rate > 0 else { return }
        if rate != cellSourceRate { rebuildCellSources(rate: rate) }

        let key = artist.lowercased()
        var entry = entries[key] ?? Entry(power: [Double](repeating: 0, count: Self.grid.count),
                                         frames: 0, preset: preset, titles: [])
        entry.preset = preset
        entry.titles.insert(title)

        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var mags  = [Float](repeating: 0, count: n / 2)
        var windowed = [Float](repeating: 0, count: n)
        var binPower = [Double](repeating: 0, count: n / 2)

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
            for k in 0..<(n / 2) { let m = Double(mags[k]); binPower[k] = m * m }
            for (c, source) in cellSources.enumerated() {
                switch source {
                case .bins(let range):
                    var sum = 0.0
                    for k in range { sum += binPower[k] }
                    entry.power[c] += sum / Double(range.count)
                case .interpolate(let lo, let hi, let t):
                    entry.power[c] += binPower[lo] * (1 - t) + binPower[hi] * t
                }
            }
            entry.frames += 1
            start += n / 2
        }

        entries[key] = entry
        writesPending += 1
        if writesPending >= 60 { save() }
    }

    /// Maps the grid onto one sample rate's bins. Called only when the rate changes — the
    /// measurement itself is untouched, because the axis it lives on is in hertz.
    private func rebuildCellSources(rate: Double) {
        let binHz = rate / Double(Self.fftSize)
        let bins = Self.fftSize / 2
        let halfCell = pow(2.0, 1.0 / (2 * Self.gridPointsPerOctave))
        cellSources = Self.grid.map { f in
            let lo = Int((f / halfCell / binHz).rounded(.down))
            let hi = Int((f * halfCell / binHz).rounded(.up))
            let clampedLo = max(1, min(lo, bins - 1))
            let clampedHi = max(clampedLo, min(hi, bins - 1))
            if clampedHi > clampedLo { return .bins(clampedLo...clampedHi) }
            let exact = f / binHz
            let k0 = max(1, min(Int(exact.rounded(.down)), bins - 2))
            return .interpolate(lower: k0, upper: k0 + 1, t: min(max(exact - Double(k0), 0), 1))
        }
        cellSourceRate = rate
    }

    // MARK: - Persistence

    struct Stored: Codable {
        var gridPointsPerOctave: Double
        var gridLow: Double
        var artists: [String: Artist]
        struct Artist: Codable {
            var frames: Int
            var preset: String
            var titles: [String]
            /// Mean power per grid cell, in dB. Absolute level is meaningless (it follows
            /// playback volume); only the shape, and shapes compared to each other, are.
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
        let stored = Stored(gridPointsPerOctave: Self.gridPointsPerOctave,
                            gridLow: Self.gridLow, artists: artists)
        // Encoding and writing happen off the main thread: this file is written while music
        // plays, and the UI has no reason to wait for it.
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    /// Restores previous sessions so a measurement can span weeks of ordinary listening.
    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.gridPointsPerOctave == Self.gridPointsPerOctave,
              stored.gridLow == Self.gridLow else { return }
        for (key, a) in stored.artists where a.frames > 0 && a.meanDB.count == Self.grid.count {
            let power = a.meanDB.map { pow(10.0, Double($0) / 10.0) * Double(a.frames) }
            entries[key] = Entry(power: power, frames: a.frames,
                                 preset: a.preset, titles: Set(a.titles))
        }
    }
}
#endif
