// MicInputDeviceStore.swift — microphone input-device selector.
//
// Ported from Flow42Core/Recording/MicInputDeviceStore.swift. The only
// coupling was `Flow42Paths.micInputDeviceFile()`; here the selection is
// persisted under the meet42 namespace (`~/.work42/meet42/mic-input-device.json`)
// via `Meet42Paths`.
//
// nil selection == "System Default": SCStreamConfiguration leaves
// microphoneCaptureDeviceID unset, so ScreenCaptureKit follows whatever
// CoreAudio currently treats as the default input device.

import AVFoundation
import Foundation
import Meet42Kit

/// A specific audio input device the user has chosen for microphone capture.
public nonisolated struct MicInputDevice: Sendable, Equatable, Codable {
    public let uid: String
    public let name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Machine-wide microphone input-device store. All functions are
/// `nonisolated` so they are safe to call from any actor or thread.
public enum MicInputDeviceStore {

    /// `~/.work42/meet42/mic-input-device.json` — the persisted selection.
    private nonisolated static func selectionFile() -> String {
        (Meet42Paths.meet42Root() as NSString)
            .appendingPathComponent("mic-input-device.json")
    }

    // MARK: - Enumeration

    /// All audio input devices currently visible to AVFoundation (built-in +
    /// USB / Bluetooth). Empty when no input devices are available.
    public nonisolated static func availableDevices() -> [MicInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map {
            MicInputDevice(uid: $0.uniqueID, name: $0.localizedName)
        }
    }

    // MARK: - Persistence

    /// The persisted device selection, or `nil` ("System Default"). Returns
    /// `nil` on any read/decode failure so absence and corrupt data read
    /// identically.
    public nonisolated static func selected() -> MicInputDevice? {
        let path = selectionFile()
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            !data.isEmpty
        else { return nil }
        return try? JSONDecoder().decode(MicInputDevice.self, from: data)
    }

    /// The `AVCaptureDevice.uniqueID` of the persisted selection, or `nil`
    /// for "System Default". Passed to
    /// `SCStreamConfiguration.microphoneCaptureDeviceID`.
    public nonisolated static func selectedUID() -> String? {
        selected()?.uid
    }

    /// Persist `device` (or `nil` to clear → "System Default"). Atomic
    /// temp-file + `rename(2)` swap so readers never see a partial write.
    /// Best-effort: errors are swallowed.
    public nonisolated static func setSelected(_ device: MicInputDevice?) {
        let path = selectionFile()
        let dir = (path as NSString).deletingLastPathComponent

        guard let device else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }

        guard let data = try? JSONEncoder().encode(device) else { return }

        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )

        let tmpPath = path + ".tmp.\(getpid())"
        do {
            try data.write(to: URL(fileURLWithPath: tmpPath))
            if rename(tmpPath, path) != 0 {
                try? FileManager.default.removeItem(atPath: tmpPath)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tmpPath)
        }
    }
}
