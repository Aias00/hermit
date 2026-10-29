import AVFoundation
import Foundation
import MoshpitKit

/// Identity is used only for continuity checks. Diagnostics omit device names,
/// identifiers and data-source identifiers.
struct MicrophoneInputSignature: Equatable, Sendable {
    struct Input: Equatable, Sendable {
        var kind: String
        var identifier: String
        var dataSourceID: Int?
    }

    var inputs: [Input]
    var sampleRate: Double
    var channelCount: UInt32
    var commonFormat: UInt
    var interleaved: Bool

    var isValid: Bool {
        !inputs.isEmpty && sampleRate.isFinite && sampleRate > 0 && channelCount > 0
    }

    func matchesFormat(_ other: Self) -> Bool {
        sampleRate == other.sampleRate && channelCount == other.channelCount
            && commonFormat == other.commonFormat && interleaved == other.interleaved
    }
}

/// Output-only route changes need not interrupt input. A stopped engine or a
/// changed input/format cannot promise uninterrupted audio: finish and offer
/// review/retry instead of silently stitching over a gap.
struct MicrophoneCaptureContinuity {
    enum Event: Sendable {
        case routeChanged, configurationChanged, interruptionBegan
        case mediaServicesLost, mediaServicesReset, bufferFormatChanged
    }

    enum EndReason: String, Equatable {
        case inputUnavailable = "input-unavailable"
        case inputChanged = "input-changed"
        case formatChanged = "format-changed"
        case engineStopped = "engine-stopped"
        case interrupted
        case mediaServicesLost = "media-services-lost"
        case mediaServicesReset = "media-services-reset"
    }

    private(set) var generation: UInt64 = 0
    private(set) var input: MicrophoneInputSignature?

    mutating func begin(_ input: MicrophoneInputSignature) -> UInt64? {
        generation &+= 1
        self.input = input.isValid ? input : nil
        return self.input == nil ? nil : generation
    }

    mutating func stop() {
        generation &+= 1
        input = nil
    }

    func isActive(_ token: UInt64) -> Bool { token == generation && input != nil }

    mutating func handle(_ event: Event, token: UInt64,
                         current: MicrophoneInputSignature?, engineRunning: Bool,
                         previousInputs: [MicrophoneInputSignature.Input]? = nil) -> EndReason? {
        guard isActive(token), let input else { return nil }
        let reason: EndReason?
        switch event {
        case .interruptionBegan: reason = .interrupted
        case .mediaServicesLost: reason = .mediaServicesLost
        case .mediaServicesReset: reason = .mediaServicesReset
        case .bufferFormatChanged: reason = .formatChanged
        case .routeChanged, .configurationChanged:
            if let current, current.isValid {
                // Activation may post its initially empty previous route after
                // recording has started. It does not describe captured input.
                // A different nonempty prior input still catches a queued
                // device switch which returned to the original device.
                if current.inputs != input.inputs
                    || previousInputs.map({ !$0.isEmpty && $0 != input.inputs }) == true {
                    reason = .inputChanged
                } else if !input.matchesFormat(current) {
                    reason = .formatChanged
                } else if !engineRunning {
                    reason = .engineStopped
                } else {
                    reason = nil
                }
            } else {
                reason = .inputUnavailable
            }
        }
        if reason != nil { self.input = nil }
        return reason
    }
}

/// close() waits for any buffer already being delivered. Session tokens also
/// prevent an old tap from feeding a later recording.
final class MicrophoneDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64?

    func open(_ token: UInt64) { lock.withLock { generation = token } }
    func close() { lock.withLock { generation = nil } }

    func close(_ token: UInt64) {
        lock.withLock {
            if generation == token { generation = nil }
        }
    }

    func deliver(_ token: UInt64, _ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard generation == token else { return }
        body()
    }
}

/// Engine/session mutations run on one control queue. Notification blocks only
/// enqueue work: an engine must not be torn down from its internal notification
/// queue. A separate tap gate quiesces delivery before removing the tap.
final class MicrophoneAudioSource: DictationAudioSource, @unchecked Sendable {
    private let control = DispatchQueue(label: "hermit.voice.capture")
    private let controlKey = DispatchSpecificKey<UInt8>()
    private let delivery = MicrophoneDeliveryGate()
    private var continuity = MicrophoneCaptureContinuity()
    private var audioEngine: AVAudioEngine?
    private var tapNode: AVAudioInputNode?
    private var observers: [NSObjectProtocol] = []
    private var ownsAudioSession = false
    private var onInterruption: (@Sendable () -> Void)?

    init() { control.setSpecific(key: controlKey, value: 1) }

    deinit { controlled { stopControlled() } }

    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable () -> Void) throws {
        try controlled {
            stopControlled()
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                        options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true, options: [])
                ownsAudioSession = true
                // Recreate after every stop, including a media-services reset.
                let engine = AVAudioEngine()
                audioEngine = engine
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                let signature = Self.signature(session: session, format: format)
                guard let token = continuity.begin(signature) else {
                    throw DictationFailure.audioCapture(String(localized: "No audio input is available."))
                }
                self.onInterruption = onInterruption
                observe(engine: engine, token: token)
                let delivery = delivery
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                    let actual = buffer.format
                    guard actual.sampleRate == signature.sampleRate,
                          actual.channelCount == signature.channelCount,
                          actual.commonFormat.rawValue == signature.commonFormat,
                          actual.isInterleaved == signature.interleaved else {
                        delivery.close(token)
                        self?.enqueue(.bufferFormatChanged, token: token)
                        return
                    }
                    delivery.deliver(token) {
                        onBuffer(buffer)
                        onLevel(Self.loudness(of: buffer))
                    }
                }
                tapNode = input
                // Open before start so the first microphone frames are kept.
                delivery.open(token)
                engine.prepare()
                try engine.start()
                let kinds = signature.inputs.map(\.kind).joined(separator: ",")
                Log.voice.info("capture started input=\(kinds, privacy: .public) sample_rate=\(signature.sampleRate) channels=\(signature.channelCount)")
            } catch {
                stopControlled()
                throw error
            }
        }
    }

    func stop() { controlled { stopControlled() } }

    private func controlled<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: controlKey) != nil { return try body() }
        return try control.sync(execute: body)
    }

    private func observe(engine: AVAudioEngine, token: UInt64) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: nil) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began {
                self?.enqueue(.interruptionBegan, token: token)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: nil) { [weak self] note in
            let route = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            self?.enqueue(.routeChanged, token: token, previousInputs: route.map(Self.inputs))
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: nil) { [weak self] _ in
            self?.enqueue(.configurationChanged, token: token)
        })
        for (name, event) in [
            (AVAudioSession.mediaServicesWereLostNotification, MicrophoneCaptureContinuity.Event.mediaServicesLost),
            (AVAudioSession.mediaServicesWereResetNotification, .mediaServicesReset)
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.enqueue(event, token: token)
            })
        }
    }

    private func enqueue(_ event: MicrophoneCaptureContinuity.Event, token: UInt64,
                         previousInputs: [MicrophoneInputSignature.Input]? = nil) {
        control.async { [weak self] in
            guard let self, continuity.isActive(token) else { return }
            let signature: MicrophoneInputSignature?
            switch event {
            case .routeChanged, .configurationChanged:
                signature = audioEngine.map {
                    Self.signature(session: .sharedInstance(), format: $0.inputNode.outputFormat(forBus: 0))
                }
            default:
                // Do not query an engine's input node after media services died.
                signature = nil
            }
            guard let reason = continuity.handle(event, token: token, current: signature,
                                                 engineRunning: audioEngine?.isRunning == true,
                                                 previousInputs: previousInputs) else { return }
            let callback = onInterruption
            stopControlled()
            Log.voice.info("capture ended reason=\(reason.rawValue, privacy: .public)")
            callback?()
        }
    }

    private func stopControlled() {
        continuity.stop()
        delivery.close()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let tapNode { tapNode.removeTap(onBus: 0) }
        tapNode = nil
        if audioEngine?.isRunning == true { audioEngine?.stop() }
        audioEngine = nil
        onInterruption = nil
        if ownsAudioSession {
            ownsAudioSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private static func inputs(_ route: AVAudioSessionRouteDescription) -> [MicrophoneInputSignature.Input] {
        route.inputs.map {
            .init(kind: $0.portType.rawValue, identifier: $0.uid,
                  dataSourceID: $0.selectedDataSource?.dataSourceID.intValue)
        }
    }

    private static func signature(session: AVAudioSession, format: AVAudioFormat) -> MicrophoneInputSignature {
        MicrophoneInputSignature(inputs: inputs(session.currentRoute), sampleRate: format.sampleRate,
                                 channelCount: format.channelCount, commonFormat: format.commonFormat.rawValue,
                                 interleaved: format.isInterleaved)
    }

    private static func loudness(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for i in 0 ..< frames { sum += channel[i] * channel[i] }
        let rms = sqrt(sum / Float(frames))
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }
}
