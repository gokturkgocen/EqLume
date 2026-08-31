#if !APP_STORE
import Foundation

/// Derives a small corrective EQ from a recording's own long-term average spectrum,
/// for music that no catalog and no classifier can name.
///
/// ## Why this exists
///
/// The genre path has a hard ceiling on this user's library. Discogs-EffNet's 400 styles
/// contain no Turkish, Anatolian, Azerbaijani, Caucasian or Middle-Eastern label at all, so
/// the classifier cannot name the material even in principle; the closest it can answer is
/// `Folk` or `.world`, and both of those presets carry no delta. A violinist with no
/// catalog presence anywhere is unreachable by every path the app has.
///
/// ## Why there is no reference curve
///
/// Automatic spectral matching is notorious, and every one of its documented failure modes
/// traces back to having an EXTERNAL reference: the choice of reference is arbitrary, the
/// result is loudness-dependent, corrections come out heavy-handed, and they end up
/// song-specific in ways that stop making sense. This uses no external reference. The
/// reference is the recording's own spectrum, smoothed to the width of the ear's critical
/// band, which also makes the whole thing immune to level: subtracting a smoothed copy of a
/// curve from itself cancels any common offset, so playback volume cannot influence it.
///
/// ## What the smoothing width means
///
/// A long-term average spectrum holds two different things at once:
///   • Its broad TILT is the music. A bozlak has no bass because no instrument in it plays
///     bass — that is not a defect to correct, and "fixing" it would add exactly the kind of
///     boost that has no business here.
///   • Its NARROW deviations are the recording: a room or body resonance, a tape-hiss shelf,
///     a microphone colouration.
/// The boundary between the two is not a matter of taste. Deviations narrower than the ear's
/// Equivalent Rectangular Bandwidth are not heard as tonal balance; broader ones are. So the
/// reference is the spectrum smoothed over exactly one ERB, using Glasberg & Moore's
/// ERB(f) = 24.7·(4.37·f_kHz + 1) Hz. That width reproduces the behaviour Room EQ Wizard
/// documents for its own ERB smoothing — about one octave at 50 Hz, half an octave at
/// 100 Hz, a third at 200 Hz, settling near a sixth above 1 kHz — which is a useful check
/// that the formula is being applied correctly.
///
/// Smoothing happens in the dB domain (a geometric mean) rather than the power domain. That
/// is deliberate and it is the opposite of what a display wants: REW's psychoacoustic
/// smoothing uses a cubic mean to weight peaks UP because it is drawing what you hear, while
/// here a peak must not be allowed to drag its own reference upward and hide itself.
///
/// TWO scales are needed, not one. Smoothing the reference over exactly one ERB lets a
/// resonance that is itself about one ERB wide cancel most of its own detection — measured
/// on a synthetic spectrum, a 7 dB resonance showed up as 1.15 dB. So the anomaly is the
/// difference between the curve smoothed at one ERB (which removes measurement noise while
/// keeping anything audible) and the same curve smoothed over three ERBs (which is the
/// timbre). Both widths stay tied to the ear's own bandwidth rather than to a chosen number
/// of octaves.
///
/// One numerical trap, found the same way: mapping onto a log grid by taking the nearest bin
/// turns the low end into a staircase, because down at 48 Hz several 1/24-octave cells fall
/// inside one 5.9 Hz FFT bin. Every step of that staircase is curvature, and a band-pass
/// operator reports curvature as resonance — it invented filters at 48 and 78 Hz on a
/// spectrum that had none. `SpectrumMeasurement` interpolates those cells rather than
/// borrowing, and hands over a curve already on this grid.
///
/// ## Fitting
///
/// Follows AutoEq's shape — build an error curve, then invert it — with its two guards that
/// matter most here: keep filters away from high-Q-plus-high-gain, and restrict boosts more
/// than cuts, since a notch does not ring. Every proposed filter is then checked against the
/// biquad magnitude it will actually realise (`FrequencyResponse`), and dropped if it fails
/// to reduce the anomaly it was meant to fix. That verification is what makes the output
/// trustworthy without running a full optimizer in the audio app.
enum AdaptiveCorrection {

    // MARK: Tunables, each with a reason

    /// Detection band. The floor is not about the FFT: below roughly 100 Hz the ear's own
    /// bandwidth is most of an octave wide, so "narrow resonance" and "tonal balance" stop
    /// being separable in principle and the method should not pretend otherwise.
    static let minFrequency = 100.0
    /// AutoEq collapses everything above 10 kHz to a single average because the measurement
    /// is not trustworthy up there. Same reasoning.
    static let maxFrequency = 10_000.0
    /// How many ERBs wide the timbre reference is. 1 ERB is the audibility threshold for a
    /// deviation; 3 is far enough above it that a resonance cannot smooth itself away.
    static let referenceERBs = 3.0
    /// 1/24-octave analysis grid: finer than the narrowest ERB we will ever smooth over
    /// (~1/5 octave), so smoothing is never limited by the grid.
    static let gridPointsPerOctave = 24.0
    /// A cut may go to −3 dB; a boost only to +1.5. Notches do not ring, and this app's
    /// whole premise is that corrections cut rather than pile on gain.
    static let maxCutDB = 3.0
    static let maxBoostDB = 1.5
    /// Below this an anomaly is not worth a filter.
    static let minMagnitudeDB = 0.7
    /// Narrower than this and a filter starts ringing audibly; wider and it stops being a
    /// resonance correction and becomes a tone control, which is the tilt we must not touch.
    static let minBandwidthOctaves = 0.2
    static let maxBandwidthOctaves = 1.5
    /// The band budget: 7 baseline filters plus at most this many measured ones.
    static let maxFilters = 3
    /// Two filters closer than this fight each other.
    static let minSeparationOctaves = 0.5
    /// An anomaly wider than this fraction of the reference window is part of the timbre
    /// that window defines, not a deviation from it. This is what keeps a filter off the
    /// KNEE of a tilt: where a recording's bass rolloff begins, the curve has real curvature,
    /// and a band-pass operator answers curvature with a broad lobe. On a synthetic spectrum
    /// whose only feature was a rolloff starting at 120 Hz, that lobe was being corrected
    /// with a −3 dB filter 1.5 octaves wide — as wide as the reference window itself.
    static let maxWidthFractionOfReference = 0.6
    /// An anomaly must fall to half its height on BOTH sides. A step or knee in the tilt
    /// produces a one-sided lobe, and this is what tells the two apart.
    static let requireTwoSidedDecay = true
    /// Cells this far below the loudest in-band cell hold no music, only noise floor.
    static let noiseFloorRangeDB = 50.0
    /// A single speaker's long-term average spectrum stabilises in 25–30 s. Music is far
    /// less stationary than one voice, and this is meant to characterise a body of
    /// recordings rather than one passage, so the bar is minutes and several tracks.
    static let minFrames = 2000            // ≈ 3 min at an 8192-point FFT, 50 % overlap
    static let minDistinctTitles = 3

    struct Proposal {
        var bands: [EQBand]
        /// RMS of the anomaly curve before and after the proposed filters, in dB. If the
        /// second number is not clearly smaller, the proposal is not worth applying.
        var anomalyRMSBefore: Double
        var anomalyRMSAfter: Double
        /// The curve the filters were fitted to, for inspection.
        var anomaly: [(frequency: Double, db: Double)]
    }

    /// Glasberg & Moore (1990) equivalent rectangular bandwidth, in Hz.
    static func erbHz(at frequency: Double) -> Double {
        24.7 * (4.37 * frequency / 1000.0 + 1.0)
    }

    /// Width, in octaves, of the window that defines the timbre reference at `f`.
    static func referenceWindowOctaves(at f: Double) -> Double {
        let half = referenceERBs * erbHz(at: f) / 2
        guard f > half else { return .infinity }
        return log2((f + half) / (f - half))
    }

    /// Peaking-filter bandwidth in octaves → Q, matching `FrequencyResponse`.
    static func qFromBandwidth(_ octaves: Double) -> Double {
        let twoN = pow(2.0, max(octaves, 0.05))
        return twoN.squareRoot() / (twoN - 1)
    }

    // MARK: The pipeline

    /// `meanDB` is mean power per grid cell in dB, on `grid`, as written by
    /// `SpectrumMeasurement`. (Mean power in dB and a magnitude response in dB are the same
    /// quantity — 10·log10 of power is 20·log10 of magnitude — so no rescaling is needed.)
    ///
    /// `verificationSampleRate` is used only to evaluate the biquad magnitudes the proposal
    /// would realise; the measurement itself is rate-independent by construction, and below
    /// 10 kHz the difference between 44.1 and 48 kHz is far too small to change a verdict.
    static func propose(meanDB: [Float], grid: [Double], frames: Int, distinctTitles: Int,
                        verificationSampleRate: Double = 48_000) -> Proposal? {
        guard frames >= minFrames, distinctTitles >= minDistinctTitles,
              meanDB.count == grid.count, grid.count > 2 else { return nil }

        let curve = meanDB.map(Double.init)
        let sampleRate = verificationSampleRate
        let audible = smoothed(curve: curve, grid: grid, erbs: 1.0)
        let timbre  = smoothed(curve: curve, grid: grid, erbs: referenceERBs)
        let anomaly = zip(audible, timbre).map { $0 - $1 }

        // Which points may be CORRECTED. The anomaly itself is deliberately left intact
        // outside this set: zeroing it manufactures a step at the band edge, and the first
        // surviving point then reads as a peak against that step — it invented a −3 dB
        // filter at exactly the 100 Hz boundary on spectra that had nothing there.
        let inBand = grid.indices.filter { grid[$0] >= minFrequency && grid[$0] <= maxFrequency }
        guard let loudest = inBand.map({ curve[$0] }).max() else { return nil }
        let valid = grid.indices.map {
            grid[$0] >= minFrequency && grid[$0] <= maxFrequency
                && curve[$0] >= loudest - noiseFloorRangeDB
        }

        let bands = fit(anomaly: anomaly, grid: grid, valid: valid)
        guard !bands.isEmpty else { return nil }

        // Score only where we are allowed to act.
        let scored = grid.indices.filter { valid[$0] }
        let before = rms(scored.map { anomaly[$0] })
        let realised = FrequencyResponse.responseDB(bands: bands, globalGainDB: 0,
                                                   sampleRate: sampleRate, freqs: grid)
        let after = rms(scored.map { anomaly[$0] + realised[$0] })
        guard after < before else { return nil }

        return Proposal(bands: bands, anomalyRMSBefore: before, anomalyRMSAfter: after,
                        anomaly: scored.map { (frequency: grid[$0], db: anomaly[$0]) })
    }

    // MARK: Steps

    static func logGrid() -> [Double] {
        let lo = 20.0, hi = 20_000.0
        let n = Int((log2(hi / lo) * gridPointsPerOctave).rounded())
        return (0...n).map { lo * pow(2.0, Double($0) / gridPointsPerOctave) }
    }

    /// Averages the curve over `erbs` ERBs around each point, in the dB domain.
    static func smoothed(curve: [Double], grid: [Double], erbs: Double) -> [Double] {
        var out = [Double](repeating: 0, count: curve.count)
        for (i, f) in grid.enumerated() {
            let half = erbs * erbHz(at: f) / 2
            let lo = f - half, hi = f + half
            var sum = 0.0, n = 0
            // The grid is monotonic, so walking outward from i is enough.
            var j = i
            while j >= 0 && grid[j] >= lo { sum += curve[j]; n += 1; j -= 1 }
            j = i + 1
            while j < grid.count && grid[j] <= hi { sum += curve[j]; n += 1; j += 1 }
            out[i] = n > 0 ? sum / Double(n) : curve[i]
        }
        return out
    }

    /// Picks the most prominent anomalies and turns each into one peaking band.
    static func fit(anomaly: [Double], grid: [Double], valid: [Bool]) -> [EQBand] {
        var candidates: [(index: Int, magnitude: Double, octaves: Double, isPeak: Bool)] = []
        for i in 1..<(anomaly.count - 1) {
            guard valid[i] else { continue }
            let v = anomaly[i]
            guard abs(v) >= minMagnitudeDB else { continue }
            let isPeak = v > 0
            // Local extremum only.
            if isPeak {
                guard v >= anomaly[i - 1], v >= anomaly[i + 1] else { continue }
            } else {
                guard v <= anomaly[i - 1], v <= anomaly[i + 1] else { continue }
            }
            guard hasTwoSidedDecay(anomaly: anomaly, at: i, isPeak: isPeak) else { continue }
            let octaves = widthOctaves(anomaly: anomaly, grid: grid, at: i, isPeak: isPeak)
            let reference = referenceWindowOctaves(at: grid[i])
            guard octaves <= maxWidthFractionOfReference * reference else { continue }
            candidates.append((i, abs(v), octaves, isPeak))
        }

        // Cuts before boosts: a notch does not ring, and this app corrects by cutting.
        candidates.sort {
            let a = $0.magnitude * ($0.isPeak ? 1.0 : 0.6)
            let b = $1.magnitude * ($1.isPeak ? 1.0 : 0.6)
            return a > b
        }

        var bands: [EQBand] = []
        var chosen: [Double] = []
        for c in candidates {
            guard bands.count < maxFilters else { break }
            let f = grid[c.index]
            // Keep filters from fighting each other.
            if chosen.contains(where: { abs(log2(f / $0)) < minSeparationOctaves }) { continue }
            let limit = c.isPeak ? maxCutDB : maxBoostDB
            let gain = (c.isPeak ? -1.0 : 1.0) * min(c.magnitude, limit)
            let octaves = min(max(c.octaves, minBandwidthOctaves), maxBandwidthOctaves)
            // AutoEq's guard: a narrow filter with a lot of gain is where ringing lives.
            // Trade gain away as the filter narrows rather than refusing outright.
            let narrowness = max(0, (0.5 - octaves) / 0.5)
            let softened = gain * (1.0 - 0.4 * narrowness)
            guard abs(softened) >= minMagnitudeDB else { continue }
            bands.append(EQBand(frequency: Float(f), gain: Float(softened),
                                bandwidth: Float(octaves), filterType: .parametric))
            chosen.append(f)
        }
        return bands
    }

    /// True when the anomaly falls to half its height on BOTH sides. A resonance is a bump;
    /// a knee or step in the tilt leaves a one-sided lobe, and that is the difference.
    static func hasTwoSidedDecay(anomaly: [Double], at i: Int, isPeak: Bool) -> Bool {
        guard requireTwoSidedDecay else { return true }
        let half = anomaly[i] / 2
        func decays(_ stride: Int) -> Bool {
            var j = i
            while j > 0 && j < anomaly.count - 1 {
                j += stride
                if isPeak ? (anomaly[j] <= half) : (anomaly[j] >= half) { return true }
            }
            return false
        }
        return decays(-1) && decays(1)
    }

    /// Width of an anomaly at half its height, in octaves.
    static func widthOctaves(anomaly: [Double], grid: [Double], at i: Int, isPeak: Bool) -> Double {
        let half = anomaly[i] / 2
        var lo = i, hi = i
        if isPeak {
            while lo > 0, anomaly[lo] > half { lo -= 1 }
            while hi < anomaly.count - 1, anomaly[hi] > half { hi += 1 }
        } else {
            while lo > 0, anomaly[lo] < half { lo -= 1 }
            while hi < anomaly.count - 1, anomaly[hi] < half { hi += 1 }
        }
        guard hi > lo else { return minBandwidthOctaves }
        return abs(log2(grid[hi] / grid[lo]))
    }

    static func rms(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return (xs.reduce(0) { $0 + $1 * $1 } / Double(xs.count)).squareRoot()
    }
}
#endif
