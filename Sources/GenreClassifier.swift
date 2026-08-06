import AVFoundation
import CoreML
import Foundation

/// Runs the Discogs-EffNet CoreML model on live audio to classify music style
/// when catalog lookup (Spotify/iTunes) fails or returns a low-confidence match.
///
/// Pipeline: arbitrary-rate mono audio -> resample to 16kHz -> mel patches ->
/// CoreML -> 400 Discogs styles -> aggregated into one of our preset families.
@available(macOS 14.2, *)
final class GenreClassifier {
    private let model: MLModel
    private let mel: MelSpectrogram
    private let styles: [String]            // 400 labels, "Parent---Style"
    private let families: [PresetFamily]    // precomputed family per style index

    /// Result of a classification pass.
    struct Result {
        let family: PresetFamily
        let confidence: Float        // share of aggregate evidence the winning family holds
        let topStyle: String         // most probable individual style (for display)
        let isReliable: Bool         // false means the UI should avoid forcing a genre
    }

    init?(resourceDir: URL) {
        let modelURL = resourceDir.appendingPathComponent("DiscogsEffNet.mlmodelc")
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let m = try? MLModel(contentsOf: modelURL, configuration: config) else {
            NSLog("GenreClassifier: failed to load model at \(modelURL.path)")
            return nil
        }
        model = m

        guard let melExtractor = MelSpectrogram(
            filterbankURL: resourceDir.appendingPathComponent("mel_filterbank_96x257.f32")
        ) else {
            NSLog("GenreClassifier: failed to init MelSpectrogram")
            return nil
        }
        mel = melExtractor

        guard let txt = try? String(contentsOf: resourceDir.appendingPathComponent("discogs_styles.txt"),
                                    encoding: .utf8) else {
            NSLog("GenreClassifier: failed to load styles")
            return nil
        }
        let parsed = txt.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parsed.count == 400 else {
            NSLog("GenreClassifier: expected 400 styles, got \(parsed.count)")
            return nil
        }
        styles = parsed
        families = parsed.map { PresetFamily.fromDiscogsStyle($0) }

        // Launch self-test: verify the Swift mel matches the Python reference.
        let selfTest = mel.selfTestMaxDiff(
            inputURL: resourceDir.appendingPathComponent("selftest_input.f32"),
            expectedMelURL: resourceDir.appendingPathComponent("selftest_mel.f32")
        )
        if let d = selfTest {
            NSLog("GenreClassifier: mel self-test max diff = \(d) (expect < 0.01)")
        } else {
            NSLog("GenreClassifier: mel self-test could not run (missing reference files)")
        }
    }

    /// Classify mono audio at `inputRate`. Returns nil if audio too short or inference fails.
    func classify(samples: [Float], inputRate: Double) -> Result? {
        guard let audio16k = Self.resampleTo16k(samples, inputRate: inputRate) else { return nil }
        let need = (MelSpectrogram.patchFrames - 1) * MelSpectrogram.hop + MelSpectrogram.frameSize
        guard audio16k.count >= need else { return nil }

        // Take up to 4 overlapping patches across the buffer; average the activations.
        var starts: [Int] = []
        let maxStart = audio16k.count - need
        let step = max(MelSpectrogram.hop * (MelSpectrogram.patchFrames / 2), 1)
        var s = 0
        while s <= maxStart && starts.count < 4 { starts.append(s); s += step }
        if starts.isEmpty { starts = [0] }

        var summed = [Float](repeating: 0, count: 400)
        var n = 0
        for start in starts {
            guard let patch = mel.patch(from: audio16k, startSample: start),
                  let acts = runModel(patch: patch) else { continue }
            for i in 0..<400 { summed[i] += acts[i] }
            n += 1
        }
        guard n > 0 else { return nil }
        for i in 0..<400 { summed[i] /= Float(n) }

        // Aggregate probabilities into preset families.
        //
        // The local (non-App-Store) build deliberately uses a bounded top-style score
        // instead of summing every label in a family. Discogs' taxonomy is very uneven:
        // "Folk, World, & Country" contains many more labels than some other families.
        // A raw sum therefore lets that large bucket win on accumulated low-probability
        // noise, which mislabeled acoustic rock as "World Music".
        var familyScore: [PresetFamily: Float] = [:]
        var total: Float = 0
        #if !APP_STORE
        var activationsByFamily: [PresetFamily: [Float]] = [:]
        for i in 0..<400 {
            activationsByFamily[families[i], default: []].append(summed[i])
        }
        for (family, activations) in activationsByFamily {
            let top = activations.sorted(by: >).prefix(3)
            let weights: [Float] = [1.0, 0.5, 0.25]
            let score = zip(top, weights).reduce(Float.zero) { $0 + $1.0 * $1.1 }
            familyScore[family] = score
            total += score
        }
        #else
        for i in 0..<400 {
            familyScore[families[i], default: 0] += summed[i]
            total += summed[i]
        }
        #endif

        // Single most-probable Discogs style (and its family).
        var topIdx = 0
        for i in 1..<400 where summed[i] > summed[topIdx] { topIdx = i }
        let topFamily = families[topIdx]

        guard let (sumWinner, sumWinnerScore) = familyScore.max(by: { $0.value < $1.value }) else { return nil }

        // Guard against the "Non-Music" grab-bag. 13 spoken-word / field-recording styles
        // plus 3 "Children's" styles (16 total) all map to .voice. A sparse, slowed, or
        // downtempo *music* track leaks a little probability into many of them, so their
        // SUMMED mass can outscore any focused music family even when no single spoken-word
        // style is actually on top. This is a music EQ and the user is listening to music,
        // so only accept .voice when the single most-probable style is itself a voice style
        // (a real podcast/audiobook puts "Spoken Word"/"Dialogue" clearly on top). Otherwise
        // fall back to the best MUSIC family.
        var chosenFamily = sumWinner
        var chosenScore = sumWinnerScore
        var shouldRejectAggregateWinner = sumWinner == .voice && topFamily != .voice
        #if !APP_STORE
        shouldRejectAggregateWinner = shouldRejectAggregateWinner
            || (sumWinner == .world && topFamily != .world)
        #endif
        if shouldRejectAggregateWinner {
            if let (fam, score) = familyScore.filter({ $0.key != sumWinner })
                                             .max(by: { $0.value < $1.value }) {
                chosenFamily = fam
                chosenScore = score
            }
        }

        let confidence = total > 0 ? chosenScore / total : 0
        #if !APP_STORE
        let runnerUpScore = familyScore
            .filter { $0.key != chosenFamily }
            .map(\.value)
            .max() ?? 0
        let margin = total > 0 ? (chosenScore - runnerUpScore) / total : 0
        // World is intentionally held to a stricter bar because it is the model's
        // broadest catch-all family. Other families still need a clear lead.
        let isReliable: Bool
        if chosenFamily == .world {
            isReliable = topFamily == .world && confidence >= 0.16 && margin >= 0.025
        } else {
            isReliable = confidence >= 0.11 && margin >= 0.012
        }
        #else
        let isReliable = true
        #endif
        return Result(family: chosenFamily, confidence: confidence,
                      topStyle: styles[topIdx], isReliable: isReliable)
    }

    private func runModel(patch: [Float]) -> [Float]? {
        guard let arr = try? MLMultiArray(shape: [1, 128, 96], dataType: .float32) else { return nil }
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: patch.count)
        for i in 0..<patch.count { ptr[i] = patch[i] }

        guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["melspectrogram": arr]),
              let out = try? model.prediction(from: provider),
              let acts = out.featureValue(for: "activations")?.multiArrayValue
        else { return nil }

        var result = [Float](repeating: 0, count: 400)
        let aptr = acts.dataPointer.bindMemory(to: Float.self, capacity: 400)
        for i in 0..<400 { result[i] = aptr[i] }
        return result
    }

    /// High-quality resample to 16kHz mono via AVAudioConverter.
    static func resampleTo16k(_ samples: [Float], inputRate: Double) -> [Float]? {
        if abs(inputRate - 16000) < 1 { return samples }
        guard !samples.isEmpty,
              let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate,
                                        channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }

        inBuf.frameLength = AVAudioFrameCount(samples.count)
        if let ch = inBuf.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                ch[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        let outCapacity = AVAudioFrameCount(Double(samples.count) * 16000.0 / inputRate + 16)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCapacity) else { return nil }

        var fed = false
        var convErr: NSError?
        let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, convErr == nil, let ch = outBuf.floatChannelData else { return nil }
        let count = Int(outBuf.frameLength)
        return Array(UnsafeBufferPointer(start: ch[0], count: count))
    }
}
