// FirebaseProjectConfig.swift — the global Firebase project selection.
//
// One file, ~/.work42/firebase/config.json, holds the project every Firebase widget and skill uses:
//
//   {"version":1,"projectId":"work42-dev","displayName":"Work42 Development"}
//
// Widgets are compiled as separate libraries, so nothing here relies on in-memory state being shared:
// the file is the only shared state. Writes replace it atomically; `FirebaseProjectStore` notices the
// replacement by polling the file's fingerprint. No credentials are ever stored here.
//
// Foundation + Observation only, so the logic tests compile it without the Work42 SDK.

import Foundation
import Observation

// MARK: - Selection

/// The persisted selection. `version` is bumped only for incompatible schema changes.
struct FirebaseProjectSelection: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var projectId: String
    var displayName: String

    init(projectId: String, displayName: String) {
        self.version = Self.currentVersion
        self.projectId = projectId
        self.displayName = displayName
    }
}

// MARK: - Errors

enum FirebaseConfigError: Error, Equatable, LocalizedError {
    /// The file exists but cannot be read (permissions, it is a directory, …).
    case unreadable(String)
    /// The file is not valid selection JSON, or its project ID is empty.
    case corrupt(String)
    /// The file was written by a newer schema version.
    case unsupportedVersion(Int)
    /// The selection could not be saved; the previous file is untouched.
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let why): "Can't read the Firebase project file: \(why)"
        case .corrupt(let why): "The Firebase project file is invalid: \(why). Choose a project to repair it."
        case .unsupportedVersion(let v): "The Firebase project file uses version \(v), which this plugin doesn't support. Update the Firebase plugin."
        case .writeFailed(let why): "Couldn't save the Firebase project: \(why)"
        }
    }
}

// MARK: - File access

enum FirebaseProjectConfig {

    /// ~/.work42/firebase/config.json for the current user. Tests inject temporary URLs instead.
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".work42", isDirectory: true)
            .appendingPathComponent("firebase", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    /// The saved selection, or nil when no file exists yet. Throws for a file that exists but can't be
    /// used, so an absent file and a damaged one are never confused. Never modifies the file.
    static func load(from url: URL = defaultURL) throws -> FirebaseProjectSelection? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        } catch {
            throw FirebaseConfigError.unreadable(error.localizedDescription)
        }
        var selection: FirebaseProjectSelection
        do {
            selection = try JSONDecoder().decode(FirebaseProjectSelection.self, from: data)
        } catch {
            // A newer schema may have dropped fields; report its version rather than "corrupt".
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["version"] as? Int, version != FirebaseProjectSelection.currentVersion {
                throw FirebaseConfigError.unsupportedVersion(version)
            }
            throw FirebaseConfigError.corrupt("not a valid selection")
        }
        guard selection.version == FirebaseProjectSelection.currentVersion else {
            throw FirebaseConfigError.unsupportedVersion(selection.version)
        }
        selection.projectId = selection.projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.projectId.isEmpty else { throw FirebaseConfigError.corrupt("projectId is empty") }
        if selection.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selection.displayName = selection.projectId
        }
        return selection
    }

    /// Writes the whole file to a temporary sibling, then renames it over the target. Readers see the old
    /// file or the new one, never a partial write, and a failure leaves the old file in place.
    static func save(_ selection: FirebaseProjectSelection, to url: URL = defaultURL) throws {
        var selection = selection
        selection.projectId = selection.projectId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.projectId.isEmpty else { throw FirebaseConfigError.writeFailed("projectId is empty") }
        if selection.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selection.displayName = selection.projectId
        }
        selection.version = FirebaseProjectSelection.currentVersion

        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(selection).write(to: temporary)
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw FirebaseConfigError.writeFailed(error.localizedDescription)
        }
    }
}

// MARK: - Fingerprint

/// Identifies a particular version of the config file. An atomic replacement always installs a new inode,
/// so comparing fingerprints detects it even when size and modification time happen to match.
struct FirebaseConfigFingerprint: Equatable, Sendable {
    var inode: UInt64
    var size: Int64
    var modified: Int64   // nanoseconds

    /// nil when the file doesn't exist.
    static func read(_ url: URL) -> FirebaseConfigFingerprint? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let nanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return FirebaseConfigFingerprint(inode: UInt64(info.st_ino), size: Int64(info.st_size), modified: nanos)
    }
}

// MARK: - Store

/// What the widgets render: no selection yet, a usable selection, or a file that needs repairing.
enum FirebaseProjectState: Equatable, Sendable {
    case none
    case selected(FirebaseProjectSelection)
    case invalid(String)

    var projectId: String? {
        if case .selected(let selection) = self { return selection.projectId }
        return nil
    }
}

/// The live view of the global selection for one widget instance. It polls the file's fingerprint once
/// per `interval` (default 1 s) while started, re-reads when it changes, and never talks to the Firebase
/// CLI. `state` only changes when the value really changes, so unchanged reads don't disturb observers.
/// Reading never writes: an invalid file stays as the user left it until they pick a project.
@MainActor
@Observable
final class FirebaseProjectStore {
    private(set) var state: FirebaseProjectState = .none

    @ObservationIgnored let url: URL
    @ObservationIgnored let interval: TimeInterval
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastFingerprint: FirebaseConfigFingerprint?

    init(url: URL = FirebaseProjectConfig.defaultURL, interval: TimeInterval = 1) {
        self.url = url
        self.interval = interval
    }

    var isRunning: Bool { task != nil }

    /// Reads now, then keeps checking until `stop()`. Call from `activate`; calling it again is a re-read.
    func start() {
        reload()
        guard task == nil else { return }
        let interval = self.interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                self?.checkForChange()
            }
        }
    }

    /// Stops checking. Call from `deactivate`.
    func stop() {
        task?.cancel()
        task = nil
    }

    /// Unconditionally re-reads the file (widget activation, window focus).
    func reload() {
        lastFingerprint = FirebaseConfigFingerprint.read(url)
        apply(Self.readState(url))
    }

    /// Persists a chosen project and adopts it immediately. Throws `FirebaseConfigError.writeFailed`, in
    /// which case the file and `state` are untouched.
    func select(_ selection: FirebaseProjectSelection) throws {
        try FirebaseProjectConfig.save(selection, to: url)
        reload()
    }

    private func checkForChange() {
        let fingerprint = FirebaseConfigFingerprint.read(url)
        guard fingerprint != lastFingerprint else { return }
        reload()
    }

    private func apply(_ new: FirebaseProjectState) {
        if new != state { state = new }
    }

    private static func readState(_ url: URL) -> FirebaseProjectState {
        do {
            if let selection = try FirebaseProjectConfig.load(from: url) { return .selected(selection) }
            return .none
        } catch {
            return .invalid(error.localizedDescription)
        }
    }
}
