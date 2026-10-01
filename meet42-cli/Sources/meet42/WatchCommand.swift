// WatchCommand.swift — `meet42 watch`: long-lived mic open/close monitor.
//
// There is no existing mic-usage monitor, so this is a minimal, self-contained
// CoreAudio poll: every ~1s we read the DEFAULT INPUT device's
// `kAudioDevicePropertyDeviceIsRunningSomewhere` flag and print a
// line-delimited JSON object on each transition, flushing stdout so a reader
// (the plugin's auto-record agent) sees events live.
//
//   {"event":"mic-open"}
//   {"event":"mic-close"}

import CoreAudio
import Foundation

enum WatchCommand {

    /// Never returns — runs the poll loop until the process is killed.
    static func watch(args: [String]) -> Never {
        // Track previous state; start from "closed" so an already-open mic
        // emits an opening transition on the first poll.
        var last = false
        while true {
            let device = defaultInputDevice()
            let running = isRunningSomewhere(device)
            if running != last {
                emit(running ? "mic-open" : "mic-close")
                last = running
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    private static func emit(_ event: String) {
        // Emit exactly the documented single-line shape, then flush so the
        // consumer gets it immediately.
        print("{\"event\":\"\(event)\"}")
        fflush(stdout)
    }

    // MARK: - CoreAudio helpers

    private static func defaultInputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : AudioDeviceID(0)
    }

    private static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        guard device != AudioDeviceID(0) else { return false }
        var result = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            device, &address, 0, nil, &size, &result
        )
        return status == noErr && result != 0
    }
}
