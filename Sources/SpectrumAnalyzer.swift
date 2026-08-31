import Accelerate
import Foundation

/// Lightweight real-time spectrum analyzer for the UI. Takes a short window of mono
/// audio, runs a 2048-point FFT, and produces N log-spaced band magnitudes (0...1)
/// with attack/decay smoothing for a lively but stable bar display.
final class SpectrumAnalyzer {
    static let fftSize = 2048
    private let log2n: vDSP_Length = 11
    let bandCount: Int

    private let fftSetup: FFTSetup
    private let window: [Float]
    private var smoothed: [Float]
    private let bandEdges: [Int]   // FFT bin index edges per band, computed per sample rate
    private var lastRate: Double = 0
    private var edgesForRate: [(lo: Int, hi: Int)] = []

    init?(bandCount: Int = 40) {
        self.bandCount = bandCount
        guard let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2)) else { return nil }
        fftSetup = setup
        var w = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
        vDSP_hann_window(&w, vDSP_Length(SpectrumAnalyzer.fftSize), Int32(vDSP_HANN_NORM))
        window = w
        smoothed = [Float](repeating: 0, count: bandCount)
        bandEdges = []
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    private func computeEdges(sampleRate: Double) {
        // A zero rate would divide to infinity and `Int(infinity)` traps, taking the app with
        // it. This runs on every output-device change, so it is worth the one line.
        guard sampleRate > 0 else { return }
        let n = SpectrumAnalyzer.fftSize
        let nyquist = sampleRate / 2
        let fMin = 30.0, fMax = min(18000.0, nyquist)
        let logMin = log10(fMin), logMax = log10(fMax)
        var edges: [(Int, Int)] = []
        for b in 0..<bandCount {
            let f0 = pow(10, logMin + (logMax - logMin) * Double(b) / Double(bandCount))
            let f1 = pow(10, logMin + (logMax - logMin) * Double(b + 1) / Double(bandCount))
            let lo = max(1, Int(f0 / sampleRate * Double(n)))
            let hi = max(lo + 1, Int(f1 / sampleRate * Double(n)))
            edges.append((lo, min(hi, n / 2)))
        }
        edgesForRate = edges
        lastRate = sampleRate
    }

    /// Compute smoothed 0...1 band levels from the most recent audio. `samples` should
    /// contain at least `fftSize` samples; the last `fftSize` are analyzed.
    func process(samples: [Float], sampleRate: Double) -> [Float] {
        let n = SpectrumAnalyzer.fftSize
        guard samples.count >= n else { return smoothed }
        if sampleRate != lastRate { computeEdges(sampleRate: sampleRate) }

        let start = samples.count - n
        var windowed = [Float](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(n))
        }

        var realp = [Float](repeating: 0, count: n / 2)
        var imagp = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        windowed.withUnsafeBufferPointer { wbuf in
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    wbuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cbuf in
                        vDSP_ctoz(cbuf, 2, &split, 1, vDSP_Length(n / 2))
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // magnitude (skip DC packing nuance; bin 0 not used by bands)
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
                }
            }
        }

        var out = [Float](repeating: 0, count: bandCount)
        let scale = Float(2.0 / Double(n))
        for (b, e) in edgesForRate.enumerated() where b < bandCount {
            var sum: Float = 0
            var cnt: Float = 0
            for k in e.lo..<e.hi { sum += mags[k]; cnt += 1 }
            let avg = cnt > 0 ? (sum / cnt) * scale : 0
            // log compression → 0..1 over ~[-60,0] dB
            let db = 20 * log10(avg + 1e-7)
            let norm = max(0, min(1, (db + 60) / 60))
            // slight low-end / treble tilt compensation for a balanced look
            out[b] = norm
        }

        // Attack fast, decay slow.
        for i in 0..<bandCount {
            if out[i] > smoothed[i] {
                smoothed[i] += (out[i] - smoothed[i]) * 0.55
            } else {
                smoothed[i] += (out[i] - smoothed[i]) * 0.18
            }
        }
        return smoothed
    }

    func reset() {
        for i in 0..<smoothed.count { smoothed[i] = 0 }
    }
}
