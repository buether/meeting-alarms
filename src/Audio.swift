import AVFoundation
import CoreAudio
import Foundation
import IOKit.pwr_mgt

// MARK: - Output volume

struct VolumeSetting: Equatable {
    var level: Int      // 0-100, matching the config file
    var muted: Bool
}

enum Volume {
    private static var defaultOutputDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Current output level and mute state, or nil when the device has no
    /// software volume — an external mixer or some USB interfaces.
    static func current() -> VolumeSetting? {
        guard let device = defaultOutputDevice else { return nil }
        var volumeAddress = address(kAudioDevicePropertyVolumeScalar)
        guard AudioObjectHasProperty(device, &volumeAddress) else { return nil }
        var scalar = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &scalar) == noErr
        else { return nil }

        var muted = false
        var muteAddress = address(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(device, &muteAddress) {
            var value = UInt32(0)
            var muteSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &muteSize, &value) == noErr {
                muted = value != 0
            }
        }
        return VolumeSetting(level: Int((scalar * 100).rounded()), muted: muted)
    }

    static func set(level: Int, muted: Bool) {
        guard let device = defaultOutputDevice else { return }
        var volumeAddress = address(kAudioDevicePropertyVolumeScalar)
        if AudioObjectHasProperty(device, &volumeAddress) {
            var settable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(device, &volumeAddress, &settable) == noErr,
               settable.boolValue {
                var scalar = Float32(max(0, min(100, level))) / 100
                AudioObjectSetPropertyData(
                    device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar
                )
            }
        }
        var muteAddress = address(kAudioDevicePropertyMute)
        if AudioObjectHasProperty(device, &muteAddress) {
            var settable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(device, &muteAddress, &settable) == noErr,
               settable.boolValue {
                var value = UInt32(muted ? 1 : 0)
                AudioObjectSetPropertyData(
                    device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
                )
            }
        }
    }
}

/// What to put back when the alarm ends, or nil to leave the output alone.
///
/// Someone who reached for the volume key mid-alarm keeps their level; only an
/// output still sitting exactly where the alarm put it gets rolled back.
func volumeRestore(saved: VolumeSetting, current: VolumeSetting?,
                   alarmLevel: Int) -> VolumeSetting? {
    guard let current, current.level == alarmLevel, !current.muted else { return nil }
    return saved
}

// MARK: - Alarm sound

/// Loops until `stop()`. The old build spawned a bash loop around `afplay` and
/// killed its process group; the player just holds the file open.
final class SoundLoop {
    private var player: AVAudioPlayer?

    func start(path: String) -> Bool {
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
            return false
        }
        player.numberOfLoops = -1
        player.volume = 1
        player.prepareToPlay()
        guard player.play() else { return false }
        self.player = player
        return true
    }

    func stop() {
        player?.stop()
        player = nil
    }
}

// MARK: - Speech

private final class SpeechWaiter: NSObject, AVSpeechSynthesizerDelegate {
    private let semaphore = DispatchSemaphore(value: 0)

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        semaphore.signal()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        semaphore.signal()
    }

    func wait(_ seconds: Double) { _ = semaphore.wait(timeout: .now() + seconds) }
}

/// Speaks once and waits, so the looping sound does not start over the top of it.
func speak(_ message: String) {
    let synthesizer = AVSpeechSynthesizer()
    let waiter = SpeechWaiter()
    synthesizer.delegate = waiter
    synthesizer.speak(AVSpeechUtterance(string: message))
    waiter.wait(15)
}

// MARK: - Display wake

/// Wakes the display, as `caffeinate -u -t 3` did.
func wakeDisplay() {
    var assertion = IOPMAssertionID(0)
    IOPMAssertionDeclareUserActivity(
        "Meeting Alarm" as CFString, kIOPMUserActiveLocal, &assertion
    )
}
