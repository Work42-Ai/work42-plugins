import Darwin
import Foundation
import Testing
@testable import Meet42Capture

@Suite struct RecordingStopPolicyTests {
    @Test func markerAlwaysStopsFirst() {
        let reason = RecordingStopPolicy.stopReason(
            markerExists: true, ownerPid: 42,
            ownerIsAlive: { _ in false }
        )
        #expect(reason == .marker)
    }

    @Test func missingOwnerStopsOwnedRecording() {
        let reason = RecordingStopPolicy.stopReason(
            markerExists: false, ownerPid: 42,
            ownerIsAlive: { _ in false }
        )
        #expect(reason == .ownerExited)
    }

    @Test func liveOrAbsentOwnerKeepsRecording() {
        #expect(RecordingStopPolicy.stopReason(
            markerExists: false, ownerPid: 42,
            ownerIsAlive: { _ in true }
        ) == nil)
        #expect(RecordingStopPolicy.stopReason(
            markerExists: false, ownerPid: nil,
            ownerIsAlive: { _ in false }
        ) == nil)
    }

    @Test func permissionErrorIsConservativelyAlive() {
        #expect(RecordingStopPolicy.processExists(killResult: -1, errorNumber: EPERM))
        #expect(!RecordingStopPolicy.processExists(killResult: -1, errorNumber: ESRCH))
    }

    @Test func recordingStateDecodesWithoutLegacyOwnerField() throws {
        let data = Data(#"{"recordingId":"r1","dir":"/tmp/r1","app":"Manual","bundleId":"","pid":123,"startedAt":"now"}"#.utf8)
        let state = try JSONDecoder().decode(RecordingState.self, from: data)
        #expect(state.ownerPid == nil)
    }
}
