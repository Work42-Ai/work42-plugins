// swift-tools-version: 6.2
//
// meet42 — the standalone, open-source macOS CLI (meet42-plugin-conversion,
// M1). A local private transcription + calendar + people tool callable by any
// agent, with NO dependency on work42/Flow42Core and its own TCC/Developer ID
// (signing wired in s7). It owns its stores (calendar.db, people.db), will
// download its own models, and carries its own usage-description plist.
//
// s6 lands the foundation: the `Meet42Kit` domain target (calendar + people
// domain, ported from Flow42Core/Calendar + Flow42Core/People, stripped of all
// work42 coupling). The capture engine (Meet42Capture, s8), the EventKit sync
// (Meet42CalendarSync, s7), and the CLI executable + verbs (s9) land in their
// own targets on top of this.

import PackageDescription

let package = Package(
    name: "meet42",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Meet42Kit", targets: ["Meet42Kit"]),
        .library(name: "Meet42CalendarSync", targets: ["Meet42CalendarSync"]),
        .library(name: "Meet42Capture", targets: ["Meet42Capture"]),
    ],
    dependencies: [
        // FluidAudio: on-device (CoreML/ANE) speaker diarization, used by
        // Meet42Capture's SpeakerDiarizationService (matches the version
        // pinned in work42/app/Package.swift).
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .target(
            name: "Meet42Kit",
            path: "Sources/Meet42Kit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "Meet42CalendarSync",
            dependencies: ["Meet42Kit"],
            path: "Sources/Meet42CalendarSync",
            linkerSettings: [.linkedFramework("EventKit")]
        ),
        // Meet42Capture (s8): audio-capture + transcription + diarization
        // engine, ported from Flow42Core/Recording + Work42App/Meetings with
        // all work42 coupling stripped. Depends on Meet42Kit for MeetingMeta
        // (the calendar-snapshot attendee cap) and FluidAudio for on-device
        // speaker diarization.
        .target(
            name: "Meet42Capture",
            dependencies: [
                "Meet42Kit",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Meet42Capture"
        ),
    ]
)
