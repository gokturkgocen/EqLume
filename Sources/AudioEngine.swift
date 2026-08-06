import AudioToolbox
import AVFAudio
import CoreAudio
import Foundation

// MARK: - Real-time globals (Core Audio IO thread cannot touch actor-isolated state)

nonisolated(unsafe) private var rtRingBuffer: AudioRingBuffer?
nonisolated(unsafe) private var rtChannelCount: UInt32 = 2
nonisolated(unsafe) private var rtScratch: UnsafeMutablePointer<Float>?
nonisolated(unsafe) private var rtScratchCapacity: Int = 0

// Mono analysis ring (for the genre classifier). Fed by the IOProc with a mono
// downmix of the tapped (pre-EQ) audio. Peeked off-thread by AutoPresetSelector.
nonisolated(unsafe) private var rtAnalysisRing: AnalysisRingBuffer?
nonisolated(unsafe) private var rtAnalysisMono: UnsafeMutablePointer<Float>?
nonisolated(unsafe) private var rtAnalysisMonoCapacity: Int = 0

/// AVAudioSourceNode render block. Pulls interleaved tapped audio from the ring buffer
/// into the AVAudioEngine non-interleaved channel buffers.
private func renderCallback(
    _: UnsafeMutablePointer<ObjCBool>,
    _: UnsafePointer<AudioTimeStamp>,
    frameCount: UInt32,
    audioBufferList: UnsafeMutablePointer<AudioBufferList>
) -> OSStatus {
    guard let ring = rtRingBuffer else { return noErr }
    let ch = Int(rtChannelCount)
    let frames = Int(frameCount)
    let interleavedCount = frames * ch
    let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)

    if rtScratchCapacity < interleavedCount {
        rtScratch?.deallocate()
        rtScratch = .allocate(capacity: interleavedCount)
        rtScratchCapacity = interleavedCount
    }
    guard let scratch = rtScratch else { return noErr }

    let read = ring.read(scratch, count: interleavedCount)
    if read < interleavedCount {
        scratch.advanced(by: read).initialize(repeating: 0, count: interleavedCount - read)
    }

    for ci in 0..<bufferList.count {
        guard let out = bufferList[ci].mData?.assumingMemoryBound(to: Float.self) else { continue }
        for f in 0..<frames {
            out[f] = scratch[f * ch + ci]
        }
    }
    return noErr
}

// MARK: - AudioEngine

@available(macOS 14.2, *)
@MainActor
final class AudioEngine {
    static let maxBands = 12

    private(set) var isRunning = false
    private(set) var outputDeviceName: String = "—"
    private(set) var lastError: String?

    /// User intention. Persists across device changes and tracks whether EQ
    /// SHOULD be running when a compatible output device is connected.
    /// `isRunning` is the current actual state and may be false even when this
    /// is true (e.g. built-in speakers are connected and we auto-bypass).
    private(set) var userWantsEQ = false

    /// Human-readable explanation when `userWantsEQ == true` but `isRunning == false`.
    /// Nil means "running as expected" or "user has it off."
    private(set) var bypassReason: String? = nil

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var engine: AVAudioEngine?
    private var eq: AVAudioUnitEQ?
    private var limiter: AVAudioUnitEffect?
    private var sourceNode: AVAudioSourceNode?
    private var ringBuffer: AudioRingBuffer?
    private var sampleRate: Double = 48000

    private var deviceChangeListener: AudioObjectPropertyListenerBlock?

    /// Separate listener for the CURRENT output device's data source. On Apple Silicon the
    /// built-in speakers and the 3.5mm jack are ONE device ID, so plugging/unplugging the Chu II
    /// does not change the default output device — it only flips `kAudioDevicePropertyDataSource`
    /// (ispk <-> hdpn). Without watching this, `reconcile()` never runs on unplug and a muted tap
    /// keeps running on a device we should be bypassing. Re-pointed whenever the default changes.
    private var dataSourceListener: AudioObjectPropertyListenerBlock?
    private var dataSourceObservedDevice = AudioObjectID(kAudioObjectUnknown)
    private var dataSourceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    var onStateChange: (() -> Void)?

    /// Sample rate of the analysis ring audio (== device/tap rate while running).
    private(set) var analysisSampleRate: Double = 48000

    /// Snapshot the most recent `seconds` of mono pre-EQ audio for genre analysis.
    /// Returns nil when not running or not enough audio has accumulated.
    func snapshotAnalysisAudio(seconds: Double) -> (samples: [Float], rate: Double)? {
        guard isRunning, let ring = rtAnalysisRing else { return nil }
        let n = Int(analysisSampleRate * seconds)
        guard let samples = ring.snapshotLast(n) else { return nil }
        return (samples, analysisSampleRate)
    }

    var activePreset: EQPreset = .flat {
        didSet { applyPreset() }
    }

    var bypassed: Bool = false {
        didSet { applyPreset() }
    }

    init() {
        refreshDeviceName()
        installDeviceChangeListener()
    }

    deinit {
        if let block = deviceChangeListener {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                DispatchQueue.main, block
            )
        }
        if let block = dataSourceListener, dataSourceObservedDevice != kAudioObjectUnknown {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                dataSourceObservedDevice, &addr, DispatchQueue.main, block
            )
        }
    }

    private func refreshDeviceName() {
        if let id = try? getDefaultOutputDeviceID(),
           let name = try? getDeviceName(id) {
            outputDeviceName = name
        }
    }

    // MARK: User-facing on/off

    /// Single user-facing toggle. Stores intention and reconciles against the current
    /// output device. If the device is the Mac's built-in speakers we leave the engine
    /// stopped — Apple's own DSP handles the speakers, and applying our headphone-targeted
    /// correction to them would do more harm than good.
    func setEnabled(_ on: Bool) {
        userWantsEQ = on
        reconcile()
    }

    /// Re-evaluates whether the engine should be running given (a) the user's intent
    /// and (b) the current output device. Called on toggle and on every device change.
    private func reconcile() {
        if userWantsEQ && shouldProcessForCurrentDevice() {
            bypassReason = nil
            if !isRunning {
                do { try startCore() } catch { lastError = error.localizedDescription }
            }
        } else {
            if isRunning { stopCore() }
        }
        onStateChange?()
    }

    private func shouldProcessForCurrentDevice() -> Bool {
        guard let id = try? getDefaultOutputDeviceID() else { return false }

        // The built-in 3.5 mm jack is the combo this app was measured for → always on,
        // with the Chu II correction.
        if outputIsBuiltinHeadphoneJack(id) {
            activeProfile = .chuII
            return true
        }

        // Built-in speakers stay off: Apple's own DSP already tunes them.
        if outputIsBuiltinSpeaker(id) {
            bypassReason = L.t("\(outputDeviceName) — EQ off (Apple's own speaker DSP is left alone)",
                               "\(outputDeviceName) — EQ kapalı (Apple'ın hoparlör DSP'sine dokunulmuyor)")
            return false
        }

        // Any other output (HDMI/DisplayPort monitor with speakers, USB DAC, Bluetooth …)
        // is opt-in per device. Once enabled it runs the DESKTOP SPEAKER profile — never the
        // in-ear correction, since that curve does not transfer to another transducer.
        if let uid = try? getDeviceUID(id), DeviceEQPolicy.isAllowed(uid: uid) {
            activeProfile = .desktopSpeakers
            return true
        }

        bypassReason = L.t("\(outputDeviceName) — EQ off (enable it for this output in settings)",
                           "\(outputDeviceName) — EQ kapalı (ayarlardan bu çıkış için aç)")
        return false
    }

    // MARK: Per-device profile

    /// Baseline correction that matches the output currently being processed.
    /// Set by `shouldProcessForCurrentDevice()`; changing it re-applies the active preset
    /// so the curve follows the device without rebuilding the audio graph.
    private(set) var activeProfile: OutputProfile = .chuII {
        didSet { if activeProfile != oldValue { applyPreset() } }
    }

    /// The active preset with the current device's baseline folded in — what actually
    /// reaches the EQ node, and what the UI should draw as the response curve.
    var resolvedPreset: EQPreset { activePreset.resolved(baseline: activeProfile.baseline) }

    /// True when the CURRENT default output is eligible for the per-device opt-in switch
    /// (i.e. not the built-in jack, which is always on, and not the built-in speakers).
    var currentOutputSupportsOptIn: Bool {
        guard let id = try? getDefaultOutputDeviceID() else { return false }
        return !outputIsBuiltinHeadphoneJack(id) && !outputIsBuiltinSpeaker(id)
    }

    /// Whether the user has enabled EQ for the current output device.
    var currentOutputAllowed: Bool {
        guard let id = try? getDefaultOutputDeviceID(),
              let uid = try? getDeviceUID(id) else { return false }
        return DeviceEQPolicy.isAllowed(uid: uid)
    }

    /// Toggle the opt-in for the current output device and reconcile immediately.
    func setCurrentOutputAllowed(_ allowed: Bool) {
        guard let id = try? getDefaultOutputDeviceID(),
              let uid = try? getDeviceUID(id) else { return }
        DeviceEQPolicy.setAllowed(allowed, uid: uid)
        if isRunning { stopCore() }   // rebuild against the new decision
        reconcile()
    }

    // MARK: Start

    private func startCore() throws {
        guard !isRunning else { return }
        lastError = nil

        // Exception safety: if ANY step below throws after the tap/aggregate are created,
        // tear them down before propagating. A global muted tap left alive by a half-finished
        // start silences the ENTIRE system until EqLume quits (the bug this guards against —
        // e.g. a device hot-plug mid-start makes aggregate/IOProc creation fail).
        var started = false
        defer { if !started { teardownAudioResources() } }

        let outputDeviceID = try getDefaultOutputDeviceID()
        let outputUID = try getDeviceUID(outputDeviceID)
        outputDeviceName = try getDeviceName(outputDeviceID)

        // 1. Build a muted global tap, excluding our own process so we don't silence ourselves.
        let myProcID = getOwnProcessAudioObjectID()
        let excludes: [AudioObjectID] = myProcID != kAudioObjectUnknown ? [myProcID] : []
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludes)
        let tapUUID = UUID()
        tapDesc.uuid = tapUUID
        tapDesc.muteBehavior = .muted
        tapDesc.name = "EqLume"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try caCheck(
            AudioHardwareCreateProcessTap(tapDesc, &newTapID),
            "Process tap oluşturulamadı"
        )
        self.tapID = newTapID

        // 2. Read the tap's stream format (channels, sample rate)
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var tapFormat = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try caCheck(
            AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fmtSize, &tapFormat),
            "Tap formatı okunamadı"
        )

        // 3. Read output device native sample rate (may differ from tap)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceRate: Float64 = 0
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(outputDeviceID, &rateAddr, 0, nil, &rateSize, &deviceRate)

        let usedRate = deviceRate > 0 ? deviceRate : tapFormat.mSampleRate
        let channels = tapFormat.mChannelsPerFrame
        self.sampleRate = usedRate

        // 4. Create a private aggregate device that includes the tap + output sub-device.
        //    Tap list MUST be specified at creation time (Apple bug: adding later returns zeroes).
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EqLume-Aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ]
            ],
        ]
        var newAggID = AudioObjectID(kAudioObjectUnknown)
        try caCheck(
            AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID),
            "Aggregate device oluşturulamadı"
        )
        self.aggregateDeviceID = newAggID

        // Wait briefly for the aggregate device to become alive
        var aliveAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for _ in 1...30 {
            var alive: UInt32 = 0
            var aliveSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(aggregateDeviceID, &aliveAddr, 0, nil, &aliveSize, &alive)
            if alive != 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // 5. Set up ring buffer + AVAudioEngine
        let ring = AudioRingBuffer(
            capacityFrames: Int(usedRate * 0.5),  // 500 ms cushion
            channels: Int(channels)
        )
        self.ringBuffer = ring
        rtRingBuffer = ring
        rtChannelCount = channels

        // Mono analysis ring: ~6 seconds at the device rate, for genre classification.
        rtAnalysisRing = AnalysisRingBuffer(capacity: Int(usedRate * 6.0))
        analysisSampleRate = usedRate

        let avEngine = AVAudioEngine()

        // Pin AVAudioEngine output directly to the real hardware device.
        // Without this, audio goes through default output which is being muted by our tap.
        var hwID = outputDeviceID
        let outAU = avEngine.outputNode.audioUnit!
        AudioUnitSetProperty(
            outAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &hwID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        let avFormat = AVAudioFormat(standardFormatWithSampleRate: usedRate,
                                     channels: AVAudioChannelCount(channels))!

        let source = AVAudioSourceNode(format: avFormat, renderBlock: renderCallback)
        self.sourceNode = source

        // Allocate a fixed maximum so we can switch between presets of different band counts
        // without rebuilding the audio graph. Unused bands are bypassed.
        let eqNode = AVAudioUnitEQ(numberOfBands: AudioEngine.maxBands)
        configureEQ(eqNode, with: resolvedPreset)
        self.eq = eqNode

        // Peak limiter at 0 dBFS guards against clipping from EQ boost.
        let limDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        let lim = AVAudioUnitEffect(audioComponentDescription: limDesc)
        AudioUnitSetParameter(lim.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.007, 0)
        AudioUnitSetParameter(lim.audioUnit, kLimiterParam_DecayTime,  kAudioUnitScope_Global, 0, 0.024, 0)
        AudioUnitSetParameter(lim.audioUnit, kLimiterParam_PreGain,    kAudioUnitScope_Global, 0, 0.0,   0)
        self.limiter = lim

        avEngine.attach(source)
        avEngine.attach(eqNode)
        avEngine.attach(lim)
        avEngine.connect(source, to: eqNode, format: avFormat)
        avEngine.connect(eqNode, to: lim, format: avFormat)
        avEngine.connect(lim, to: avEngine.outputNode, format: avFormat)

        try avEngine.start()
        self.engine = avEngine

        // 6. Install IOProc on the aggregate device — it reads tapped audio into the ring buffer
        //    and writes silence to the aggregate's output (real playback goes through AVAudioEngine).
        let ioBlock: AudioDeviceIOBlock = { _, inInput, _, outOutput, _ in
            guard let ring = rtRingBuffer else { return }
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            for i in 0..<inList.count {
                guard let p = inList[i].mData else { continue }
                let count = Int(inList[i].mDataByteSize) / MemoryLayout<Float>.size
                let fp = p.assumingMemoryBound(to: Float.self)
                ring.write(fp, count: count)

                // Feed the analysis ring with a mono downmix (buffer 0 only; tap is
                // interleaved stereo). Averages channels per frame.
                if i == 0, let analysis = rtAnalysisRing {
                    let ch = max(Int(rtChannelCount), 1)
                    let frames = count / ch
                    if frames > 0 {
                        if rtAnalysisMonoCapacity < frames {
                            rtAnalysisMono?.deallocate()
                            rtAnalysisMono = .allocate(capacity: frames)
                            rtAnalysisMonoCapacity = frames
                        }
                        if let mono = rtAnalysisMono {
                            let inv = Float(1) / Float(ch)
                            for f in 0..<frames {
                                var sum: Float = 0
                                let base = f * ch
                                for c in 0..<ch { sum += fp[base + c] }
                                mono[f] = sum * inv
                            }
                            analysis.write(mono, count: frames)
                        }
                    }
                }
            }
            let outList = UnsafeMutableAudioBufferListPointer(outOutput)
            for i in 0..<outList.count {
                if let p = outList[i].mData {
                    memset(p, 0, Int(outList[i].mDataByteSize))
                }
            }
        }
        var newProcID: AudioDeviceIOProcID?
        try caCheck(
            AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateDeviceID, nil, ioBlock),
            "IOProc oluşturulamadı"
        )
        self.procID = newProcID

        try caCheck(
            AudioDeviceStart(aggregateDeviceID, procID),
            "Aggregate device başlatılamadı"
        )

        isRunning = true
        started = true
        onStateChange?()
    }

    // MARK: Stop

    /// Idempotent teardown of every CoreAudio / AVAudioEngine resource. Safe to call at any
    /// time, including when `isRunning` is false — this is what guarantees a partially-started
    /// or orphaned global muted tap can never keep the whole Mac silenced. Each resource is
    /// guarded by its own sentinel, so repeated calls are harmless no-ops.
    private func teardownAudioResources() {
        if let procID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            self.procID = nil
        }

        engine?.stop()
        engine = nil
        eq = nil
        limiter = nil
        sourceNode = nil

        rtRingBuffer = nil
        ringBuffer = nil
        rtAnalysisRing = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        // Destroy the process tap LAST and UNCONDITIONALLY. It is a global muted tap: while it
        // exists it mutes every other app's audio system-wide, so a dangling tap = the whole
        // system stays silent until the process exits.
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func stopCore() {
        let wasRunning = isRunning
        isRunning = false
        // Always tear down — do NOT early-return on `!isRunning`. A start that threw partway
        // leaves `isRunning == false` while the muted tap is still alive; only an unconditional
        // teardown clears that orphaned tap (otherwise the Mac stays muted until EqLume quits).
        teardownAudioResources()
        if wasRunning { onStateChange?() }
    }

    // MARK: EQ application

    private func configureEQ(_ node: AVAudioUnitEQ, with preset: EQPreset) {
        for i in 0..<node.bands.count {
            let nodeBand = node.bands[i]
            if i < preset.bands.count {
                let band = preset.bands[i]
                nodeBand.filterType = band.filterType.avType
                nodeBand.frequency = band.frequency
                nodeBand.bandwidth = band.bandwidth
                nodeBand.gain = band.gain
                nodeBand.bypass = false
            } else {
                nodeBand.bypass = true
            }
        }
        // Final EQ gain = preamp (negative, prevents clipping from boosts) +
        //                 makeup (positive, restores loudness lost to cuts).
        // The limiter at 0 dBFS catches any rare combined peak.
        node.globalGain = preset.globalGainDB
        node.bypass = bypassed || preset.bands.isEmpty
    }

    private func applyPreset() {
        guard let eq else { return }
        // Resolved: the genre delta plus whatever baseline the ACTIVE OUTPUT calls for.
        configureEQ(eq, with: resolvedPreset)
        limiter?.bypass = bypassed
    }

    // MARK: Output device changes

    private func installDeviceChangeListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handleDeviceChange()
                }
            }
        }
        deviceChangeListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            DispatchQueue.main, block
        )
        updateDataSourceListener()
    }

    /// (Re)attach the data-source listener to whatever the current default output device is,
    /// so a headphone-jack plug/unplug (which does NOT change the default device on Apple
    /// Silicon) still triggers `reconcile()` via `handleDeviceChange`.
    private func updateDataSourceListener() {
        let newDevice = (try? getDefaultOutputDeviceID()) ?? kAudioObjectUnknown
        guard newDevice != dataSourceObservedDevice else { return }

        if let block = dataSourceListener, dataSourceObservedDevice != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(
                dataSourceObservedDevice, &dataSourceAddress, DispatchQueue.main, block
            )
        }

        dataSourceObservedDevice = newDevice
        guard newDevice != kAudioObjectUnknown else { return }

        let block = dataSourceListener ?? { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleDeviceChange() }
            }
        }
        dataSourceListener = block
        AudioObjectAddPropertyListenerBlock(
            newDevice, &dataSourceAddress, DispatchQueue.main, block
        )
    }

    private var isRestarting = false

    private func handleDeviceChange() {
        guard !isRestarting else { return }
        refreshDeviceName()
        updateDataSourceListener()   // re-point the jack listener onto the new default device
        // Always re-reconcile when the device changes: this handles three cases at once —
        //   1) Headphones unplugged → speakers connected → stop engine
        //   2) Speakers active → headphones plugged in → start engine (if user enabled it)
        //   3) Headphones swapped (different model) → restart on new sample rate
        isRestarting = true
        stopCore()
        if userWantsEQ && shouldProcessForCurrentDevice() {
            do { try startCore() } catch { lastError = error.localizedDescription }
        }
        isRestarting = false
        onStateChange?()
    }
}
