// MicsCommand.swift — `meet42 mics`: list input devices for the in-widget
// mic picker. Backed by Meet42Capture's `MicInputDeviceStore`.

import Foundation
import Meet42Capture

enum MicsCommand {

    private struct MicRow: Encodable {
        let uid: String
        let name: String
        let selected: Bool
    }

    static func mics(args: [String]) {
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
}
