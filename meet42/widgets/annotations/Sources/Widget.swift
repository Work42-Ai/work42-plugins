// Widget.swift — meet42's My Notes (annotations) widget
// (meet42-plugin-conversion, s12).
//
// A faithful, identical-UI port of the app's AnnotationsWidgetView
// (`Sources/Work42App/Meetings/AnnotationsWidgetView.swift`) into a plugin
// widget that links ONLY Work42WidgetKit + Work42UI. An editable notes tile
// whose content persists to `<dir>/annotations.md` inside the session dir so
// it is part of the session and readable by the agent.
//
// The original leaned on three app/Flow42Core symbols that a plugin widget
// can't import; each is replaced with a small self-contained equivalent:
//   - Flow42Core.AnnotationsStore (path/load/atomic-save) → local free
//     functions doing direct file I/O with a temp-file + rename atomic save.
//   - Flow42Core.SessionLatestFile (the atomic-write recipe)              → same.
//   - Work42App.FileWatcher (reload on external change)                   → a
//     local Timer-based mtime/size poller (WidgetFileWatcher).
//
// Behaviour (unchanged from the original):
//   - Load on appear; placeholder when the file is absent.
//   - Save on edit: debounced (~500 ms) atomic write so a concurrent reader
//     never sees a half-written file.
//   - Reload guard: external changes only reload when the tile is NOT focused
//     AND has no unsaved local edits.
//
// SESSION FILE (read + write): <dir>/annotations.md

import Foundation
import Observation
import SwiftUI
import Work42UI
import Work42WidgetKit

// MARK: - Annotations file I/O (local AnnotationsStore replacement)

/// Absolute path to `annotations.md` inside the session dir.
private func annotationsPath(sessionDir: String) -> String {
    (sessionDir as NSString).appendingPathComponent("annotations.md")
}

/// Read the current annotations, or "" when the file is absent/unreadable.
private func loadAnnotations(sessionDir: String) -> String {
    (try? String(contentsOfFile: annotationsPath(sessionDir: sessionDir), encoding: .utf8)) ?? ""
}

/// Atomic write: temp file in the same dir + rename, so a concurrent watcher
/// reader never sees a half-written file (the `SessionLatestFile` recipe).
private func saveAnnotations(sessionDir: String, text: String) throws {
    try FileManager.default.createDirectory(
        atPath: sessionDir, withIntermediateDirectories: true
    )
    let dest = URL(fileURLWithPath: annotationsPath(sessionDir: sessionDir))
    try Data(text.utf8).write(to: dest, options: .atomic)
}

// MARK: - WidgetFileWatcher (local FileWatcher reimplementation)

/// Minimal self-contained replacement for `Work42App.FileWatcher`. Polls the
/// file's (mtime, size) signature every second and bumps `version` on change.
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

// MARK: - AnnotationsWidget

@Observable
@MainActor
final class AnnotationsWidget: Work42Widget, Work42WidgetPill {

    let id = "annotations"
    let title = "Meet42 My Notes"
    let icon = "square.and.pencil"
    var linkIntents: [WidgetLinkIntentSpec] { [] }
    var minSize: WidgetMinSize { WidgetMinSize(width: 220, height: 160) }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(AnnotationsWidgetView(sessionDir: services.worktreePath ?? ""))
    }

    // MARK: Work42WidgetPill

    func makePillView(services: SessionServices) -> AnyView? {
        AnyView(AnnotationsPillView(sessionDir: services.worktreePath ?? ""))
    }

    var pillMetadata: WidgetPillMetadata {
        WidgetPillMetadata(
            preferredSize: WidgetMinSize(width: 320, height: 220),
            title: title,
            icon: icon
        )
    }
}

// MARK: - AnnotationsWidgetView (ported)

/// Editable personal annotations tile. Faithful port of the app view, with the
/// loading-state plumbing dropped (plugin widgets own their own chrome).
private struct AnnotationsWidgetView: View {

    let sessionDir: String

    @State private var text: String = ""
    @State private var isDirty: Bool = false
    @FocusState private var isFocused: Bool
    @State private var lastSavedText: String = ""
    @State private var watcher = WidgetFileWatcher()
    @State private var saveTimer: Timer? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider().opacity(0.4)
            editorArea
        }
        .onAppear {
            let path = annotationsPath(sessionDir: sessionDir)
            let contents = loadAnnotations(sessionDir: sessionDir)
            text          = contents
            lastSavedText = contents
            isDirty       = false
            watcher.watch(path)
        }
        .onChange(of: watcher.version) {
            // External change detected. Only reload if we have no local edits
            // and the editor is not focused — guarding against clobbering
            // in-flight user input.
            guard !isDirty, !isFocused else { return }
            let onDisk = loadAnnotations(sessionDir: sessionDir)
            guard onDisk != text else { return }
            text = onDisk
            lastSavedText = onDisk
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: DT.s8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: DT.f11, weight: .medium))
                .foregroundStyle(DT.textTertiary)
            Text("MY NOTES")
                .font(.system(size: DT.f9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(DT.textTertiary)
            Spacer(minLength: 0)
            if isDirty {
                Text("Saving…")
                    .font(.system(size: DT.f9))
                    .foregroundStyle(DT.textTertiary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DT.s12)
        .padding(.vertical, DT.s8)
        .animation(.easeInOut(duration: 0.2), value: isDirty)
    }

    // MARK: - Editor

    private var editorArea: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !isFocused {
                placeholder
            }
            TextEditor(text: $text)
                .focused($isFocused)
                .font(.system(size: DT.f13))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, DT.s12)
                .padding(.vertical, DT.s8)
                .onChange(of: text) { _, newValue in
                    isDirty = true
                    scheduleDebounce(text: newValue)
                }
        }
    }

    private var placeholder: some View {
        Text("Jot personal notes — captured here and readable by the agent.")
            .font(.system(size: DT.f13))
            .foregroundStyle(DT.textTertiary)
            .allowsHitTesting(false)
            .padding(.horizontal, DT.s16)
            .padding(.vertical, DT.s12)
    }

    // MARK: - Persistence

    /// Arms (or re-arms) the 500 ms debounce timer. Each keystroke resets
    /// the countdown; the file is only written once the user pauses.
    private func scheduleDebounce(text: String) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    commitToDisk(text: text)
                }
            }
        }
    }

    private func commitToDisk(text: String) {
        do {
            try saveAnnotations(sessionDir: sessionDir, text: text)
            lastSavedText = text
            isDirty = false
        } catch {
            fputs("[annotations] write failed: \(error)\n", stderr)
        }
    }
}

// MARK: - AnnotationsPillView (compact editor)

/// Compact pill rendering: the editor without the header chrome. Same
/// load/debounced-atomic-save persistence as the full widget.
private struct AnnotationsPillView: View {

    let sessionDir: String

    @State private var text: String = ""
    @State private var isDirty: Bool = false
    @FocusState private var isFocused: Bool
    @State private var watcher = WidgetFileWatcher()
    @State private var saveTimer: Timer? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty && !isFocused {
                Text("Jot personal notes…")
                    .font(.system(size: DT.f12))
                    .foregroundStyle(DT.textTertiary)
                    .allowsHitTesting(false)
                    .padding(.horizontal, DT.s12)
                    .padding(.vertical, DT.s8)
            }
            TextEditor(text: $text)
                .focused($isFocused)
                .font(.system(size: DT.f12))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, DT.s8)
                .padding(.vertical, DT.s4)
                .onChange(of: text) { _, newValue in
                    isDirty = true
                    scheduleDebounce(text: newValue)
                }
        }
        .onAppear {
            let contents = loadAnnotations(sessionDir: sessionDir)
            text = contents
            isDirty = false
            watcher.watch(annotationsPath(sessionDir: sessionDir))
        }
        .onChange(of: watcher.version) {
            guard !isDirty, !isFocused else { return }
            let onDisk = loadAnnotations(sessionDir: sessionDir)
            guard onDisk != text else { return }
            text = onDisk
        }
    }

    private func scheduleDebounce(text: String) {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    do {
                        try saveAnnotations(sessionDir: sessionDir, text: text)
                        isDirty = false
                    } catch {
                        fputs("[annotations] write failed: \(error)\n", stderr)
                    }
                }
            }
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
        result = WidgetEntryPoint.register(AnnotationsWidget())
    }
    return result
}
