// SyncCommand.swift — `meet42 sync`: request EventKit access and run one
// full sync into calendar.db via Meet42CalendarSync.
//
// ⚠️ TCC: EventKit access is keyed to the signed binary identity; under a
// plain `swift build` (ad-hoc) the grant won't persist across rebuilds. The
// control flow here is correct regardless.

import Foundation
import Meet42Kit
import Meet42CalendarSync

@MainActor
enum SyncCommand {

    private struct SyncResult: Encodable {
        let synced: Bool
        let count: Int?
        let message: String
    }

    static func sync(args: [String]) async {
        let store: CalendarStore
        do {
            store = try CalendarStore()
        } catch {
            CLI.fail("meet42 sync: couldn't open calendar.db: \(error)", code: 2)
        }
        let service = Meet42CalendarSync(store: store)
        let count = await service.syncOnce()

        let result: SyncResult
        if let count {
            result = SyncResult(
                synced: true, count: count,
                message: "Synced \(count) event(s) from EventKit."
            )
        } else {
            result = SyncResult(
                synced: false, count: nil,
                message: "Calendar access was not granted. Grant Calendar access to meet42 and retry."
            )
        }

        if CLI.wantsJSON(args) {
            CLI.emitJSON(result)
        } else {
            print(result.message)
        }
        if !result.synced { exit(1) }
    }
}
