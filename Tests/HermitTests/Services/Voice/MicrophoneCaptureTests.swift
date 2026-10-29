import Foundation
import Testing
@testable import Moshpit

@Suite("Microphone capture continuity")
struct MicrophoneCaptureTests {
    private func microphone(rate: Double = 48_000, identifier: String = "built-in") -> MicrophoneInputSignature {
        MicrophoneInputSignature(inputs: [.init(kind: "MicrophoneBuiltIn", identifier: identifier, dataSourceID: nil)],
                                 sampleRate: rate, channelCount: 1, commonFormat: 1, interleaved: false)
    }

    @Test("Output-only and redundant configuration notifications keep valid input")
    func unchangedInputContinues() throws {
        var capture = MicrophoneCaptureContinuity()
        let input = microphone()
        let tokenCandidate = capture.begin(input)
        let token = try #require(tokenCandidate)
        #expect(capture.handle(.routeChanged, token: token, current: input, engineRunning: true,
                               previousInputs: input.inputs) == nil)
        #expect(capture.handle(.configurationChanged, token: token, current: input,
                               engineRunning: true) == nil)
        // setActive can announce its initially empty previous route late.
        #expect(capture.handle(.routeChanged, token: token, current: input, engineRunning: true,
                               previousInputs: []) == nil)
        #expect(capture.isActive(token))
    }

    @Test("Changing devices of the same port type still ends the recording")
    func sameTypeDifferentDeviceEnds() throws {
        var capture = MicrophoneCaptureContinuity()
        let tokenCandidate = capture.begin(microphone(identifier: "headset-a"))
        let token = try #require(tokenCandidate)
        #expect(capture.handle(.routeChanged, token: token, current: microphone(identifier: "headset-b"),
                               engineRunning: true) == .inputChanged)
        #expect(!capture.isActive(token))
    }

    @Test("A route which changed and returned before delivery is not silently joined")
    func queuedRouteRoundTripEnds() throws {
        var capture = MicrophoneCaptureContinuity()
        let input = microphone()
        let tokenCandidate = capture.begin(input)
        let token = try #require(tokenCandidate)
        #expect(capture.handle(.routeChanged, token: token, current: input, engineRunning: true,
                               previousInputs: microphone(identifier: "headset").inputs) == .inputChanged)
    }

    @Test("An input data source change is a continuity boundary")
    func selectedDataSourceChanges() throws {
        var capture = MicrophoneCaptureContinuity()
        let tokenCandidate = capture.begin(microphone())
        let token = try #require(tokenCandidate)
        var next = microphone()
        next.inputs[0].dataSourceID = 2
        #expect(capture.handle(.routeChanged, token: token, current: next,
                               engineRunning: true) == .inputChanged)
    }

    @Test("A new capture format ends rather than losing or reinterpreting frames")
    func changedFormatEnds() throws {
        for change in 0..<4 {
            var capture = MicrophoneCaptureContinuity()
            let tokenCandidate = capture.begin(microphone())
            let token = try #require(tokenCandidate)
            var next = microphone()
            switch change {
            case 0: next.sampleRate = 16_000
            case 1: next.channelCount = 2
            case 2: next.commonFormat = 3
            default: next.interleaved = true
            }
            #expect(capture.handle(.configurationChanged, token: token, current: next,
                                   engineRunning: true) == .formatChanged)
        }
    }

    @Test("Missing or unusable input cannot keep recording alive")
    func unavailableInputEnds() throws {
        var invalid = microphone()
        invalid.inputs = []
        for input in [nil, invalid, microphone(rate: 0), microphone(rate: .nan)] {
            var capture = MicrophoneCaptureContinuity()
            let tokenCandidate = capture.begin(microphone())
            let token = try #require(tokenCandidate)
            #expect(capture.handle(.routeChanged, token: token, current: input,
                                   engineRunning: false) == .inputUnavailable)
        }
        var capture = MicrophoneCaptureContinuity()
        #expect(capture.begin(invalid) == nil)
        #expect(capture.input == nil)
    }

    @Test("A stopped engine ends the recording without an automatic restart")
    func stoppedEngineEnds() throws {
        var capture = MicrophoneCaptureContinuity()
        let input = microphone()
        let tokenCandidate = capture.begin(input)
        let token = try #require(tokenCandidate)
        #expect(capture.handle(.configurationChanged, token: token, current: input,
                               engineRunning: false) == .engineStopped)
        // Even if an external engine later resumes, this recording stays done.
        #expect(capture.handle(.configurationChanged, token: token, current: input,
                               engineRunning: true) == nil)
        #expect(!capture.isActive(token))
    }

    @Test("Interruptions and media-service events end exactly once")
    func interruptionsEndOnce() throws {
        let events: [(MicrophoneCaptureContinuity.Event, MicrophoneCaptureContinuity.EndReason)] = [
            (.interruptionBegan, .interrupted), (.mediaServicesLost, .mediaServicesLost),
            (.mediaServicesReset, .mediaServicesReset), (.bufferFormatChanged, .formatChanged)
        ]
        for (event, expected) in events {
            var capture = MicrophoneCaptureContinuity()
            let tokenCandidate = capture.begin(microphone())
            let token = try #require(tokenCandidate)
            #expect(capture.handle(event, token: token, current: nil, engineRunning: false) == expected)
            #expect(capture.handle(event, token: token, current: nil, engineRunning: false) == nil)
            #expect(!capture.isActive(token))
        }
    }

    @Test("Notifications captured before Stop cannot end a later recording")
    func staleNotificationCannotAffectNewCapture() throws {
        var capture = MicrophoneCaptureContinuity()
        let firstCandidate = capture.begin(microphone())
        let first = try #require(firstCandidate)
        capture.stop()
        #expect(capture.handle(.interruptionBegan, token: first, current: nil, engineRunning: false) == nil)
        let secondCandidate = capture.begin(microphone())
        let second = try #require(secondCandidate)
        #expect(first != second)
        #expect(capture.handle(.mediaServicesReset, token: first, current: nil, engineRunning: false) == nil)
        #expect(capture.isActive(second))
    }

    @Test("Old taps and a late old-format notification cannot deliver or close a new session")
    func tapGenerationsAreIsolated() {
        let gate = MicrophoneDeliveryGate()
        var delivered = 0
        gate.open(1)
        gate.deliver(1) { delivered += 1 }
        gate.close()
        gate.deliver(1) { delivered += 100 }
        gate.open(2)
        gate.deliver(1) { delivered += 100 }
        gate.close(1)
        gate.deliver(2) { delivered += 1 }
        #expect(delivered == 2)
    }

    @Test("Stop quiesces an in-flight buffer before closing the tap")
    func closingWaitsForBufferDelivery() {
        let gate = MicrophoneDeliveryGate()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let deliveryDone = DispatchSemaphore(value: 0)
        let closeEntered = DispatchSemaphore(value: 0)
        let closeDone = DispatchSemaphore(value: 0)
        gate.open(1)
        DispatchQueue.global().async {
            gate.deliver(1) {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
            deliveryDone.signal()
        }
        #expect(entered.wait(timeout: .now() + 1) == .success)
        DispatchQueue.global().async {
            closeEntered.signal()
            gate.close()
            closeDone.signal()
        }
        #expect(closeEntered.wait(timeout: .now() + 1) == .success)
        #expect(closeDone.wait(timeout: .now() + 0.02) == .timedOut)
        release.signal()
        #expect(deliveryDone.wait(timeout: .now() + 1) == .success)
        #expect(closeDone.wait(timeout: .now() + 1) == .success)
        var deliveredAfterStop = false
        gate.deliver(1) { deliveredAfterStop = true }
        #expect(!deliveredAfterStop)
    }
}
