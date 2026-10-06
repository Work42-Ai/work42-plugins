// MicsCommand.swift — `meet42 mics`: list input devices for the in-widget
// mic picker, and persist a mic selection. Backed by Meet42Capture's
// `MicInputDeviceStore`.

import Foundation
import Meet42Capture

enum MicsCommand {

    private struct MicRow: Encodable {
        let uid: String
        let name: String
        let selected: Bool
    }

    private struct SelectResult: Encodable {
        let uid: String
        let name: String
        let selected: Bool
    }

    static func mics(args: [String]) {
        // Dispatch subcommands first.
        if CLI.firstPositional(args) == "select" {
            selectMic(args: args)
            return
        }

        // Default: list all input devices.
        let devices = MicInputDeviceStore.availableDevices()
        let selectedUID = MicInputDeviceStore.selectedUID()
        let rows = devices.map {
            MicRow(uid: $0.uid, name: $0.name, selected: $0.uid == selectedUID)
        }
        if CLI.wantsJSON(args) {
            CLI.emitJSON(rows)
            return
        }
        if rows.isEmpty {
            print("No input devices found.")
            return
        }
        for r in rows {
            let marker = r.selected ? " *" : ""
            print("\(CLI.padded(r.name, 40)) \(r.uid)\(marker)")
        }
        if selectedUID == nil {
            print("(no explicit selection — using System Default)")
        }
    }

    // MARK: - select <uid>

    /// Persist a microphone selection so the next `meet42 record` uses it.
    /// Idempotent — safe to call multiple times for the same uid. If the
    /// device uid is not currently visible (e.g. temporarily disconnected),
    /// the selection is persisted with the uid as a fallback name and will
    /// apply when the device reconnects.
    private static func selectMic(args: [String]) {
        // positionals: ["select", <uid>]
        let pos = CLI.positionals(args)
        guard pos.count >= 2 else {
            CLI.fail("meet42 mics select: usage: mics select <uid>")
        }
        let uid = pos[1]

        // Prefer the device's localised name; fall back to uid as a
        // human-readable label if the device is not currently enumerated.
        let devices = MicInputDeviceStore.availableDevices()
        let device = devices.first(where: { $0.uid == uid })
            ?? MicInputDevice(uid: uid, name: uid)

        MicInputDeviceStore.setSelected(device)

        if CLI.wantsJSON(args) {
            CLI.emitJSON(SelectResult(uid: device.uid, name: device.name, selected: true))
        } else {
            print("Selected microphone: \(device.name)")
        }
    }
}
