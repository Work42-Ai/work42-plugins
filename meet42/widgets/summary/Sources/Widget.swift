// Widget.swift — meet42's Summary widget (meet42-plugin-conversion, s12).
//
// A faithful, identical-UI port of the app's SummaryWidgetView
// (`Sources/Work42App/Meetings/SummaryWidgetView.swift`) into a plugin widget
// that links ONLY Work42WidgetKit + Work42UI. The tile is empty until the
// end-of-meeting agent pass writes `<dir>/summary.md`, then renders that file
// as themed markdown.
//
// Two app/Flow42Core symbols the original used are replaced:
//   - Work42App.FileWatcher (reload on write)  → a local Timer-based mtime/size
//     poller (WidgetFileWatcher).
//   - Work42UI.MarkdownPreview                 → Work42UI.Work42MarkdownDocument
//     (SDK-promoted themed markdown with artifact embeds + the shared comment
//     layer), per the confirmed design.
//
// SESSION FILE (read-only): <dir>/summary.md

import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42WidgetKit

// MARK: - WidgetFileWatcher (local FileWatcher reimplementation)

/// Minimal self-contained replacement for `Work42App.FileWatcher`. Polls the
/// file's (mtime, size) signature every second and bumps `version` on change,
/// so the body re-reads `summary.md` when the end-of-meeting pass writes it.
@Observable
@MainActor
final class WidgetFileWatcher {

    private(set) var version = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var path: String?
    @ObservationIgnored private var lastSignature = ""

    func watch(_ path: String) {
        guard self.path != path else { return }
        self.path = path
        lastSignature = Self.signature(of: path)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.poll() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let path else { return }
        let sig = Self.signature(of: path)
        guard sig != lastSignature else { return }
        lastSignature = sig
        version &+= 1
    }

    private static func signature(of path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int) ?? 0
        return "\(mtime)-\(size)"
    }
}

/// Absolute path to `summary.md` inside `dir`.
private func summaryPath(dir: String) -> String {
    (dir as NSString).appendingPathComponent("summary.md")
}

// MARK: - SummaryWidget

@Observable
@MainActor
final class SummaryWidget: Work42Widget, Work42WidgetPill {

    let id = "summary"
    let title = "Summary"
    let icon = "doc.text"
    var linkIntents: [WidgetLinkIntentSpec] { [] }
    var minSize: WidgetMinSize { WidgetMinSize(width: 240, height: 160) }

    private var services: SessionServices?

    func activate(services: SessionServices) {
        self.services = services
        // Register the session so inline [[artifact:id]] embeds in summary.md
        // resolve through the artifact server (same as the built-in spec widget).
        if let sessionId = services.sessionId, let worktreePath = services.worktreePath {
            try? ArtifactRuntime.register(sessionId: sessionId, directory: worktreePath)
        }
    }

    func deactivate() {
        services = nil
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(SummaryWidgetView(services: services))
    }

    // MARK: Work42WidgetPill

    func makePillView(services: SessionServices) -> AnyView? {
        AnyView(SummaryPillView(services: services))
    }

    var pillMetadata: WidgetPillMetadata {
        WidgetPillMetadata(
            preferredSize: WidgetMinSize(width: 340, height: 280),
            title: title,
            icon: icon
        )
    }
}

// MARK: - SummaryWidgetView (ported)

/// Meeting Summary tile. Faithful port of the app view, with the loading-state
/// plumbing dropped and MarkdownPreview swapped for Work42MarkdownDocument.
private struct SummaryWidgetView: View {

    let services: SessionServices

    @State private var watcher = WidgetFileWatcher()

    var body: some View {
        // Read `version` so SwiftUI tracks the watcher as a dependency and
        // re-runs this view whenever `summary.md` is written or updated on disk.
        let _ = watcher.version
        let dir = services.worktreePath ?? ""
        let path = summaryPath(dir: dir)
        let body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        return VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider().opacity(0.4)
            if !body.isEmpty {
                Work42MarkdownDocument(
                    text: body,
                    sessionId: services.sessionId,
                    commentKey: "summary",
                    artifactsEnabled: true,
                    baseURL: services.worktreePath.map { URL(fileURLWithPath: $0) }
                )
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            watcher.watch(path)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: DT.s8) {
            Image(systemName: "doc.text")
                .font(.system(size: DT.f11, weight: .medium))
                .foregroundStyle(DT.textTertiary)
            Text("SUMMARY")
                .font(.system(size: DT.f9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DT.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DT.s12)
        .padding(.vertical, DT.s8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            Text("Summary not yet available")
                .font(.system(size: DT.f13, weight: .semibold))
                .foregroundStyle(.primary)
            Text("The agent will write a structured summary here when the meeting ends — decisions, action items, open questions, and best-effort speaker attribution.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
        }
        .padding(DT.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SummaryPillView (compact, scrollable markdown)

/// Compact pill rendering: the summary markdown (or empty state), no header.
private struct SummaryPillView: View {

    let services: SessionServices

    @State private var watcher = WidgetFileWatcher()

    var body: some View {
        let _ = watcher.version
        let dir = services.worktreePath ?? ""
        let path = summaryPath(dir: dir)
        let body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""

        return Group {
            if !body.isEmpty {
                Work42MarkdownDocument(
                    text: body,
                    sessionId: services.sessionId,
                    commentKey: "summary",
                    artifactsEnabled: true,
                    baseURL: services.worktreePath.map { URL(fileURLWithPath: $0) }
                )
            } else {
                Text("Summary not yet available")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.secondary)
                    .padding(DT.s12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            watcher.watch(path)
        }
    }
}

// MARK: - Widget entry-point ABI

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(SummaryWidget())
    }
    return result
}
