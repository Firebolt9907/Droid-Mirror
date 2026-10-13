import CoreAudio
import Foundation

enum MacAudioActivity {
    static func isOutputActive() -> Bool {
        var outputDevice = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultOutput = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutput, 0, nil, &size, &outputDevice
        ) == noErr, outputDevice != kAudioObjectUnknown else { return false }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        var isRunning = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            outputDevice, &isRunning, 0, nil, &size, &running
        ) == noErr else { return false }
        return running != 0
    }

    static func hasSustainedPlayback() async -> Bool {
        guard isOutputActive() else { return false }
        try? await Task.sleep(for: .milliseconds(300))
        return isOutputActive()
    }
}
