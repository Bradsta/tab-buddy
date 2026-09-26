//
//  TutorAudioSession.swift
//  TabBuddy
//
//  Owns the tutor's microphone input (TUTOR_IMPLEMENTATION.md §4):
//  `.playAndRecord` + `.measurement` (no AGC or voice processing), one input
//  tap, take recording to a mono Float32 .caf, and the take clock (0 = first
//  input sample). While listening, app output is muted: observers of
//  `.tutorListeningWillStart` stop their audio and `TutorSynth` refuses to play.
//
//  iPad is the primary device: it usually sits on a stand 0.5–1.5 m from the
//  instrument, so levels are lower and the room louder. Gating is therefore
//  adaptive (tracked noise floor, see ListeningOnsetDetector) and the route
//  key distinguishes the input port (built-in mic vs USB-C/Lightning
//  interfaces vs headset mics) as well as the output.
//

import AVFoundation
import Combine
import os

extension Notification.Name {
    /// Posted on the main thread just before tutor listening starts. Stop any audio output.
    static let tutorListeningWillStart = Notification.Name("TabBuddy.tutorListeningWillStart")
    /// Posted on the main thread after tutor listening stopped (by a caller,
    /// an interruption, or an audio configuration change).
    static let tutorListeningDidStop = Notification.Name("TabBuddy.tutorListeningDidStop")
}

/// One block of mono input on the take clock.
struct TutorAudioChunk {
    var samples: [Float]
    /// Take-clock index (input rate) of the first sample.
    var startSample: Int
    var sampleRate: Double
    /// Host time of the first sample (0 if unknown).
    var hostTime: UInt64
}

enum TutorAudioError: Error, LocalizedError {
    case permissionDenied
    case noInput
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone access is off. Turn it on in Settings to use listening lessons."
        case .noInput: return "No microphone input is available."
        case .engineFailed(let why): return "Audio input could not start (\(why))."
        }
    }
}

@MainActor
final class TutorAudioSession: ObservableObject {
    static let shared = TutorAudioSession()

    // MARK: Output mute (readable from any thread)

    private nonisolated static let muteState = OSAllocatedUnfairLock(initialState: false)
    /// True while graded listening runs; app audio must stay silent.
    nonisolated static var outputMuted: Bool { muteState.withLock { $0 } }

    // MARK: Published state

    @Published private(set) var isListening = false
    @Published private(set) var permissionDenied = false
    /// Input level 0...1 (-80...0 dBFS, smoothed) for meters.
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var inputLevelDBFS: Float = -120
    /// Tracked room-noise floor.
    @Published private(set) var noiseFloorDBFS: Float = -120
    /// Recent peak level (decays ~10 dB/s).
    @Published private(set) var peakDBFS: Float = -120
    @Published private(set) var routeKey: String = TutorAudioSession.currentRouteKey()

    /// Take recording of the current/last session.
    private(set) var takeURL: URL?
    private(set) var sampleRate: Double = 0

    /// Serial queue on which consumers receive chunks.
    nonisolated let processingQueue = DispatchQueue(label: "TabBuddy.TutorAudio", qos: .userInitiated)

    private var engine = AVAudioEngine()
    /// Set after a configuration change (route or sample-rate change): the
    /// next start builds a fresh engine so the tap sees the new hardware format.
    private var engineNeedsReset = false
    private let pipeline: TapPipeline
    private var outputMutedBySession = false
    private var clickPlayer: AVAudioPlayerNode?
    private var observers: [NSObjectProtocol] = []
    private var engineObserver: NSObjectProtocol?
    /// A start is awaiting permission; later starts wait for it to settle so
    /// the tap is never installed twice.
    private var starting = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    /// Stop the mode reset from undoing a listening session that starts right after.
    private var modeResetGeneration = 0

    private init() {
        pipeline = TapPipeline(queue: processingQueue)
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.routeKey = TutorAudioSession.currentRouteKey() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                if type == .began { MainActor.assumeIsolated { _ = self?.stop() } }
            })
        observeEngineConfiguration()
    }

    /// The engine stops itself on a configuration change (route change,
    /// sample-rate change, media services reset). Stop listening so observers
    /// learn about it, and rebuild the engine on the next start.
    private func observeEngineConfiguration() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // The engine stops itself when the hardware format changed; a
                    // late notice from our own session setup finds it running.
                    guard let self, !self.engine.isRunning else { return }
                    self.engineNeedsReset = true
                    _ = self.stop()
                }
            }
    }

    private func resetEngineIfNeeded() {
        guard engineNeedsReset else { return }
        engineNeedsReset = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        observeEngineConfiguration()
    }

    // MARK: Route

    /// Route key for latency calibration, e.g. `out=Speaker;in=MicrophoneBuiltIn`
    /// or `out=USBAudio;in=USBAudio`. Output and input ports both matter.
    ///
    /// The key describes the route tutor listening uses (`.playAndRecord`,
    /// speaker by default, Bluetooth A2DP but not HFP), so it is the same
    /// before, during, and after listening: while the session is in a
    /// playback-only category the input is predicted from the preferred and
    /// available inputs instead of reading as "none".
    nonisolated static func currentRouteKey() -> String {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        return routeKey(outputs: route.outputs.map(\.portType), inputs: route.inputs.map(\.portType),
                        preferredInput: session.preferredInput?.portType,
                        availableInputs: session.availableInputs?.map(\.portType) ?? [])
    }

    /// Pure form of `currentRouteKey()` (testable).
    nonisolated static func routeKey(outputs: [AVAudioSession.Port], inputs: [AVAudioSession.Port],
                                     preferredInput: AVAudioSession.Port?,
                                     availableInputs: [AVAudioSession.Port]) -> String {
        // Listening uses .defaultToSpeaker and A2DP only.
        let outPorts = outputs.map { port -> AVAudioSession.Port in
            switch port {
            case .builtInReceiver: return .builtInSpeaker
            case .bluetoothHFP: return .bluetoothA2DP
            default: return port
            }
        }
        var inPorts = inputs.filter { $0 != .bluetoothHFP }
        if inPorts.isEmpty {
            if let preferredInput, preferredInput != .bluetoothHFP {
                inPorts = [preferredInput]
            } else {
                // Wired and USB inputs take over from the built-in microphone.
                let external: [AVAudioSession.Port] = [.usbAudio, .headsetMic, .lineIn, .carAudio]
                inPorts = [external.first(where: availableInputs.contains) ?? .builtInMic]
            }
        }
        let outs = Array(Set(outPorts.map(\.rawValue))).sorted().joined(separator: "+")
        let ins = Array(Set(inPorts.map(\.rawValue))).sorted().joined(separator: "+")
        return "out=\(outs.isEmpty ? AVAudioSession.Port.builtInSpeaker.rawValue : outs);in=\(ins)"
    }

    /// Keys written before routes were predicted can say `in=none`; they
    /// never describe a listening route and are ignored.
    nonisolated static func isUsableRouteKey(_ key: String) -> Bool {
        !key.contains("in=none") && !key.contains("out=none")
    }

    nonisolated static var isBluetoothOutput: Bool {
        let bt: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { bt.contains($0.portType) }
    }

    // MARK: Consumers

    /// Registers a block called on `processingQueue` with every input chunk.
    nonisolated func addConsumer(_ block: @escaping (TutorAudioChunk) -> Void) -> UUID {
        pipeline.addConsumer(block)
    }

    nonisolated func removeConsumer(_ id: UUID) {
        pipeline.removeConsumer(id)
    }

    /// Seconds of input received in the current take (not latency-corrected).
    /// Lags real time by the tap's delivery delay (up to a buffer or more), so
    /// visual cues use `currentTakeTime` instead.
    nonisolated var takeClock: TimeInterval { pipeline.takeClock }

    /// Take-clock seconds for a host time, mapped through the latest tap
    /// buffer's timestamp (nil before the first buffer).
    nonisolated func takeTime(forHostTime hostTime: UInt64) -> TimeInterval? {
        pipeline.takeTime(forHostTime: hostTime)
    }

    /// Take-clock seconds of "now" on the host clock (falls back to the sample
    /// count before the first buffer).
    nonisolated var currentTakeTime: TimeInterval {
        pipeline.takeTime(forHostTime: mach_absolute_time()) ?? pipeline.takeClock
    }

    // MARK: Start / stop

    /// Starts listening.
    /// - Parameters:
    ///   - recordTake: write the input to a .caf take file.
    ///   - muteOutput: post `.tutorListeningWillStart` and mute app output
    ///     (false only for latency calibration, which plays clicks).
    ///   - shouldContinue: checked after the permission prompt; returning
    ///     false (the caller stopped meanwhile) cancels the start with
    ///     `CancellationError` before any input is opened.
    func start(recordTake: Bool = true, muteOutput: Bool = true,
               shouldContinue: (() -> Bool)? = nil) async throws {
        while starting {
            await withCheckedContinuation { startWaiters.append($0) }
        }
        guard !isListening else { return }
        starting = true
        defer {
            starting = false
            let waiters = startWaiters
            startWaiters = []
            for w in waiters { w.resume() }
        }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            permissionDenied = true
            throw TutorAudioError.permissionDenied
        }
        permissionDenied = false
        guard shouldContinue?() ?? true, !Task.isCancelled else { throw CancellationError() }
        modeResetGeneration += 1
        resetEngineIfNeeded()

        if muteOutput {
            NotificationCenter.default.post(name: .tutorListeningWillStart, object: self)
            Self.muteState.withLock { $0 = true }
            outputMutedBySession = true
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP])
            // Small IO buffers keep tap timestamps and onsets close to real time.
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
        } catch {
            unmute()
            throw TutorAudioError.engineFailed(error.localizedDescription)
        }

        let input = engine.inputNode
        // The hardware format: a stale output format after a route change
        // trips the tap's sample-rate assertion.
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            unmute()
            throw TutorAudioError.noInput
        }
        sampleRate = format.sampleRate

        var url: URL?
        if recordTake {
            url = Self.newTakeURL()
        }
        do {
            try pipeline.begin(sampleRate: format.sampleRate, recordTo: url)
        } catch {
            unmute()
            throw TutorAudioError.engineFailed(error.localizedDescription)
        }
        takeURL = url

        if !muteOutput {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let outFormat = AVAudioFormat(standardFormatWithSampleRate: engine.outputNode.outputFormat(forBus: 0).sampleRate > 0
                                          ? engine.outputNode.outputFormat(forBus: 0).sampleRate : 48000, channels: 1)!
            engine.connect(player, to: engine.mainMixerNode, format: outFormat)
            clickPlayer = player
        }

        let pipeline = self.pipeline
        pipeline.onLevel = { [weak self] rms, noise, peak in
            DispatchQueue.main.async {
                guard let self else { return }
                let db = 20 * log10(max(rms, 1e-6))
                self.inputLevelDBFS = db
                self.inputLevel = max(0, min(1, (db + 80) / 80))
                self.noiseFloorDBFS = 20 * log10(max(noise, 1e-6))
                self.peakDBFS = 20 * log10(max(peak, 1e-6))
            }
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, when in
            pipeline.receive(buffer, when: when)
        }

        do {
            engine.prepare()
            try engine.start()
            clickPlayer?.play()
        } catch {
            input.removeTap(onBus: 0)
            detachClickPlayer()
            _ = pipeline.finish()
            unmute()
            throw TutorAudioError.engineFailed(error.localizedDescription)
        }
        routeKey = Self.currentRouteKey()
        isListening = true
    }

    /// Stops listening, closes the take file, unmutes output, and posts
    /// `.tutorListeningDidStop`. Returns the take URL (if recorded).
    @discardableResult
    func stop() -> URL? {
        guard isListening else {
            unmute()
            return takeURL
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        detachClickPlayer()
        _ = pipeline.finish()
        isListening = false
        inputLevel = 0
        unmute()
        scheduleModeReset()
        NotificationCenter.default.post(name: .tutorListeningDidStop, object: self)
        return takeURL
    }

    /// `.measurement` turns off input processing and lowers output gain on
    /// some devices; return to `.default` once listening has stopped (unless
    /// it started again meanwhile).
    private func scheduleModeReset() {
        let generation = modeResetGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isListening, !self.starting,
                      generation == self.modeResetGeneration else { return }
                let session = AVAudioSession.sharedInstance()
                guard session.mode == .measurement else { return }
                try? session.setCategory(.playAndRecord, mode: .default,
                                         options: [.defaultToSpeaker, .allowBluetoothA2DP])
            }
        }
    }

    private func unmute() {
        if outputMutedBySession {
            Self.muteState.withLock { $0 = false }
            outputMutedBySession = false
        }
    }

    private func detachClickPlayer() {
        if let p = clickPlayer {
            p.stop()
            engine.detach(p)
            clickPlayer = nil
        }
    }

    // MARK: Calibration clicks

    /// Schedules audible clicks (only when started with `muteOutput: false`).
    /// Returns the clicks' take-clock times, or nil if output is unavailable.
    func scheduleClicks(count: Int, interval: TimeInterval, leadIn: TimeInterval = 0.6) -> [TimeInterval]? {
        guard isListening, let player = clickPlayer, !Self.outputMuted,
              pipeline.firstHostTime != nil else { return nil }
        let format = player.outputFormat(forBus: 0)
        guard let click = TutorClickSound.buffer(format: format, accent: false),
              let accent = TutorClickSound.buffer(format: format, accent: true) else { return nil }
        let now = mach_absolute_time()
        var times: [TimeInterval] = []
        for i in 0..<count {
            let at = now + AVAudioTime.hostTime(forSeconds: leadIn + Double(i) * interval)
            player.scheduleBuffer(i == 0 ? accent : click, at: AVAudioTime(hostTime: at))
            guard let t = pipeline.takeTime(forHostTime: at) else { return nil }
            times.append(t)
        }
        return times
    }

    // MARK: Files

    /// Directory for fresh take recordings (WP-C moves kept takes to Application Support).
    nonisolated static var takesDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TutorTakes", isDirectory: true)
    }

    private static func newTakeURL() -> URL {
        let dir = takesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return dir.appendingPathComponent("take-\(stamp)-\(UUID().uuidString.prefix(8)).caf")
    }
}

// MARK: - Tap pipeline (off the main actor)

/// Receives tap buffers, writes the take, tracks levels, and fans chunks out
/// to consumers on the processing queue.
private final class TapPipeline: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = OSAllocatedUnfairLock()
    private var consumers: [UUID: (TutorAudioChunk) -> Void] = [:]
    private var file: AVAudioFile?
    private var fileFormat: AVAudioFormat?
    private var samplesReceived = 0
    private var rate: Double = 0
    private var hostAtFirstSample: UInt64?
    private var clockMap = TakeClockMap()
    private var noise: Float = 0
    private var peak: Float = 0
    private var lastLevelSample = 0
    /// (rms, noise floor, peak) roughly every 50 ms; called on the processing queue.
    var onLevel: ((Float, Float, Float) -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    var firstHostTime: UInt64? { lock.withLock { hostAtFirstSample } }

    var takeClock: TimeInterval {
        lock.withLock { rate > 0 ? Double(samplesReceived) / rate : 0 }
    }

    func takeTime(forHostTime host: UInt64) -> TimeInterval? {
        let map = lock.withLock { clockMap }
        return map.takeTime(hostSeconds: AVAudioTime.seconds(forHostTime: host))
    }

    func addConsumer(_ block: @escaping (TutorAudioChunk) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { consumers[id] = block }
        return id
    }

    func removeConsumer(_ id: UUID) {
        lock.withLock { _ = consumers.removeValue(forKey: id) }
    }

    func begin(sampleRate: Double, recordTo url: URL?) throws {
        var newFile: AVAudioFile?
        var fmt: AVAudioFormat?
        if let url {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true,
            ]
            newFile = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                channels: 1, interleaved: false)
        }
        queue.sync {
            file = newFile
            fileFormat = fmt
            noise = 0
            peak = 0
            lastLevelSample = 0
        }
        lock.withLock {
            samplesReceived = 0
            rate = sampleRate
            hostAtFirstSample = nil
            clockMap = TakeClockMap()
        }
    }

    /// Tap callback (audio thread): copy channel 0 and hand off.
    func receive(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: n))
        let host = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
        let hostSeconds = AVAudioTime.seconds(forHostTime: host)
        let (start, sr): (Int, Double) = lock.withLock {
            if hostAtFirstSample == nil { hostAtFirstSample = host }
            let s = samplesReceived
            samplesReceived += n
            clockMap.anchor(sample: s, hostSeconds: hostSeconds, rate: rate)
            return (s, rate)
        }
        queue.async { [self] in
            handle(TutorAudioChunk(samples: samples, startSample: start, sampleRate: sr, hostTime: host))
        }
    }

    private func handle(_ chunk: TutorAudioChunk) {
        if let file, let fmt = fileFormat,
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk.samples.count)) {
            buf.frameLength = AVAudioFrameCount(chunk.samples.count)
            chunk.samples.withUnsafeBufferPointer { src in
                buf.floatChannelData![0].update(from: src.baseAddress!, count: chunk.samples.count)
            }
            try? file.write(from: buf)
        }
        let rms = ListeningStats.rms(chunk.samples[...])
        if noise == 0 || rms < noise { noise = noise == 0 ? rms : 0.8 * noise + 0.2 * rms }
        else { noise = min(noise * 1.01, rms) }
        let chunkPeak = chunk.samples.reduce(0) { max($0, abs($1)) }
        peak = max(chunkPeak, peak * pow(0.316, Float(chunk.samples.count) / Float(max(1, chunk.sampleRate))))
        if chunk.startSample - lastLevelSample >= Int(chunk.sampleRate * 0.05) {
            lastLevelSample = chunk.startSample
            onLevel?(rms, noise, peak)
        }
        let blocks = lock.withLock { Array(consumers.values) }
        for b in blocks { b(chunk) }
    }

    /// Closes the take file after pending chunks are handled.
    func finish() -> Bool {
        queue.sync {
            let had = file != nil
            file = nil
            fileFormat = nil
            return had
        }
    }
}

// MARK: - Take clock mapping

/// Maps host time to take-clock seconds through the latest tap buffer's
/// timestamp (sample index ↔ host time of its first sample). Samples arrive
/// in buffers some time after they were captured, so the sample count alone
/// lags real time by the delivery delay; the timestamp mapping does not.
struct TakeClockMap: Sendable {
    private var anchorSample = 0
    private var anchorHost: Double?
    private var rate: Double = 0

    init() {}

    mutating func anchor(sample: Int, hostSeconds: Double, rate: Double) {
        anchorSample = sample
        anchorHost = hostSeconds
        self.rate = rate
    }

    /// Take seconds for a host time (seconds); nil before the first buffer.
    func takeTime(hostSeconds: Double) -> TimeInterval? {
        guard let anchorHost, rate > 0 else { return nil }
        return Double(anchorSample) / rate + (hostSeconds - anchorHost)
    }
}

// MARK: - Click sound

enum TutorClickSound {
    /// A short 2 kHz (accent 2.8 kHz) click burst.
    static func buffer(format: AVAudioFormat, accent: Bool) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(rate * 0.03)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let ch = buf.floatChannelData else { return nil }
        buf.frameLength = frames
        let f = accent ? 2800.0 : 2000.0
        for c in 0..<Int(format.channelCount) {
            for i in 0..<Int(frames) {
                let t = Double(i) / rate
                ch[c][i] = Float(0.6 * sin(2 * .pi * f * t) * exp(-t / 0.006))
            }
        }
        return buf
    }
}
