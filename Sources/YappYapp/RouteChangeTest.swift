import AVFoundation
import CoreAudio
import Foundation

/// ROUTE-CHANGE-FIX (wiredRouteChange): live harness for the shipped capture
/// path. It records through the real RecordingController (an AVCaptureSession,
/// not an AVAudioEngine) while flipping the system default input device. The
/// shipped recovery hangs off AVCaptureSession runtime-error / interruption /
/// device-disconnect notifications, so this harness validates capture-session
/// route-change recovery and the onIrrecoverableInterruption graceful finish,
/// not the deleted AVAudioEngine reconfiguration path. On some Macs the
/// capture session transparently follows the new default input without an
/// interruption, which is also correct; the manual QA step distinguishes the
/// two. Run with --route-change-test. The original default input device is
/// restored before exit.
enum RouteChangeTest {
    /// Mutated only on the main run loop; the box exists so the start task
    /// can hand its result back without a Sendable capture warning.
    private final class StartFlag: @unchecked Sendable {
        var done = false
        var error: Error?
    }

    static func run() -> Never {
        let recorder = RecordingController()
        var interruptions = 0
        recorder.onIrrecoverableInterruption = { reason in
            interruptions += 1
            print("graceful interruption callback fired: \(reason.message)")
        }

        let startFlag = StartFlag()
        Task { @MainActor in
            do {
                try await recorder.start()
            } catch {
                startFlag.error = error
            }
            startFlag.done = true
        }
        pump(until: { startFlag.done }, timeout: 10)

        if let error = startFlag.error {
            print("ROUTE-CHANGE TEST FAILED: recorder did not start: \(error)")
            exit(2)
        }
        guard startFlag.done else {
            print("ROUTE-CHANGE TEST FAILED: start timed out (microphone permission prompt?)")
            exit(2)
        }
        print("recording started")

        let original = defaultInputDeviceID()

        let devices = AudioInputDevices.all()
        print("input devices: \(devices.map(\.name).joined(separator: ", "))")

        // Prefer real microphones over capture cards; two devices are enough
        // to bounce the default input back and forth.
        let microphones = devices.filter { $0.name.localizedCaseInsensitiveContains("microphone") || $0.name.localizedCaseInsensitiveContains("shure") }
        let pool = (microphones.count >= 2 ? microphones : devices)
            .prefix(2)
            .compactMap { AudioInputDevices.deviceID(forUID: $0.uid) }

        guard pool.count >= 2 else {
            restore(original)
            print("ROUTE-CHANGE TEST SKIPPED: need two input devices to force route changes")
            exit(0)
        }

        var flips = 0
        let flipDeadline = Date().addingTimeInterval(13)
        var nextFlip = Date().addingTimeInterval(1)

        while Date() < flipDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if Date() >= nextFlip {
                let target = pool[flips % pool.count]
                setDefaultInputDevice(target)
                flips += 1
                print("flip \(flips): default input -> device \(target)")
                // One flip per routeChangeRecoveryDebounce window so each
                // device change can drive the capture-session recovery path
                // (wiredRouteChange) and its debounced finish decision.
                nextFlip = Date().addingTimeInterval(0.8)
            }
        }

        restore(original)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        let url = recorder.stop()
        print("recorder stopped cleanly, capture: \(url?.lastPathComponent ?? "discarded (too short)")")
        recorder.cleanup(url)

        // ROUTE-CHANGE-FIX (wiredRouteChange): the AVAudioEngine parking path
        // is gone, so there is no retired-engine drain window to outlive. Hold
        // the run loop briefly so any in-flight capture-session teardown and
        // debounced recovery work items settle before we assert no crash.
        print("settling capture-session teardown...")
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))

        // YA-58: zero interruptions proves nothing about recovery, so it is
        // never reported as a pass.
        let verdict = RouteChangeVerdict.evaluate(flips: flips, interruptions: interruptions)
        print(verdict.line)
        exit(verdict.exitCode)
    }

    static func printDevices() -> Never {
        let defaultID = defaultInputDeviceID()
        let devices = AudioInputDevices.all()

        print("Route-change test device inventory")
        if devices.isEmpty {
            print("No input devices reported by CoreAudio.")
            exit(0)
        }

        for device in devices {
            let deviceID = AudioInputDevices.deviceID(forUID: device.uid)
            let marker = deviceID == defaultID ? "default" : "available"
            print("- \(device.name) [\(marker)] uid=\(device.uid)")
        }

        if devices.count < 2 {
            print("Live route-change test will skip: at least two input devices are needed.")
        } else {
            print("Live route-change test can run with: ./scripts/route_change_test.sh --run")
        }
        exit(0)
    }

    private static func pump(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private static func restore(_ deviceID: AudioDeviceID?) {
        if let deviceID {
            setDefaultInputDevice(deviceID)
        }
    }

    private static func makeDefaultInputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = makeDefaultInputAddress()
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func setDefaultInputDevice(_ deviceID: AudioDeviceID) {
        var address = makeDefaultInputAddress()
        var device = deviceID
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device
        )
    }
}

/// YA-58: the route-change harness only passes when a device flip actually
/// drove the graceful-finish recovery path.
enum RouteChangeVerdict: Equatable {
    case passed(flips: Int, interruptions: Int)
    case unproven(flips: Int)

    static func evaluate(flips: Int, interruptions: Int) -> RouteChangeVerdict {
        flips > 0 && interruptions > 0
            ? .passed(flips: flips, interruptions: interruptions)
            : .unproven(flips: flips)
    }

    var line: String {
        switch self {
        case let .passed(flips, interruptions):
            "ROUTE-CHANGE TEST PASSED: \(flips) device flips, \(interruptions) graceful interruptions, no crash"
        case let .unproven(flips):
            "ROUTE-CHANGE TEST NOT PROVEN: \(flips) device flips, 0 graceful interruptions. No crash, but recovery was never exercised; check by hand that the capture followed the new input."
        }
    }

    var exitCode: Int32 {
        switch self {
        case .passed: 0
        case .unproven: 3
        }
    }
}
