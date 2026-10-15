// Logic tests for FirebaseProjectConfig / FirebaseProjectStore / parser / lister / picker model.
// Plain executable (no XCTest), same shape as linear42's Tests/LogicTests. Exits non-zero on any failure.

import CoreGraphics
import Foundation
import ImageIO

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

func checkA(_ condition: @autoclosure () async -> Bool, _ message: String, line: Int = #line) async {
    let passed = await condition()
    check(passed, message, line: line)
}

func makeTempDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("firebase-logic-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func entry(_ id: String, _ name: String? = nil) -> FirebaseProjectEntry {
    FirebaseProjectEntry(projectId: id, displayName: name ?? id)
}

func project(_ id: String, _ name: String? = nil) -> FirebaseProject {
    FirebaseProject(projectId: id, displayName: name ?? id)
}

func configError(_ body: () throws -> Any?) -> FirebaseConfigError? {
    do { _ = try body(); return nil } catch let error as FirebaseConfigError { return error } catch { return nil }
}

func envelope(_ projects: [(String, String?)]) -> String {
    let items = projects.map { id, name in
        name.map { "{\"projectId\":\"\(id)\",\"displayName\":\"\($0)\",\"projectNumber\":\"1\"}" } ?? "{\"projectId\":\"\(id)\"}"
    }
    return "{\"status\":\"success\",\"result\":[\(items.joined(separator: ","))]}"
}

/// A fake shell. Counts calls, records commands, optionally delays.
final class FakeShell: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private func record(_ command: String) { lock.lock(); _calls.append(command); lock.unlock() }
    var result: FirebaseShellResult
    var delayNanos: UInt64 = 0
    var error: Error?

    init(_ result: FirebaseShellResult) { self.result = result }

    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    var runner: FirebaseShellRunner {
        { [self] command in
            record(command)
            if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
            if let error { throw error }
            return result
        }
    }
}

func ok(_ stdout: String) -> FirebaseShellResult { FirebaseShellResult(stdout: stdout, stderr: "", exitCode: 0) }

// MARK: - Config file

func testConfigFile() {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("firebase/config.json")
    func write(_ text: String) { try! text.write(to: url, atomically: false, encoding: .utf8) }

    check((try? FirebaseProjectConfig.load(from: url)) == [], "absent file loads as an empty list, not an error")

    try! FirebaseProjectConfig.save([entry("work42-dev", "Work42 Development"), entry("work42-prod", "Work42 Production")], to: url)
    check(FileManager.default.fileExists(atPath: url.path), "save creates intermediate directories")
    check((try? FirebaseProjectConfig.load(from: url)) == [entry("work42-dev", "Work42 Development"), entry("work42-prod", "Work42 Production")], "round trip keeps order")
    let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    check(Set(json.keys) == ["version", "projects"] && json["version"] as? Int == 2, "file is version 2 with a projects list: \(json.keys)")
    let items = json["projects"] as! [[String: Any]]
    check(items.count == 2 && items.allSatisfy { Set($0.keys) == ["projectId", "displayName"] }, "each project holds exactly projectId/displayName")
    let leftovers = try! FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    check(leftovers == ["config.json"], "no temp files left behind: \(leftovers)")

    // An empty list is a valid file, distinct from no file.
    try! FirebaseProjectConfig.save([], to: url)
    check(FileManager.default.fileExists(atPath: url.path) && (try? FirebaseProjectConfig.load(from: url)) == [], "empty list saves and loads")

    // Normalisation: trimmed IDs, blank names fall back to the ID, repeated IDs keep the first.
    try! FirebaseProjectConfig.save([FirebaseProjectEntry(projectId: " p1 ", displayName: "  "), entry("p2", "Two"), entry("p1", "Again"), entry("p2", "Dup")], to: url)
    check((try? FirebaseProjectConfig.load(from: url)) == [entry("p1"), entry("p2", "Two")], "save trims, falls back to the ID and dedupes")
    write("{\"version\":2,\"projects\":[{\"projectId\":\"a\",\"displayName\":\"First\"},{\"projectId\":\" a \"},{\"projectId\":\"b\"}]}")
    check((try? FirebaseProjectConfig.load(from: url)) == [entry("a", "First"), entry("b")], "load dedupes repeated IDs keeping the first, missing name → ID")

    // Version 1 (plugin 0.1.0) is read as one project and left alone until the next save.
    write("{\"version\":1,\"projectId\":\"old-proj\",\"displayName\":\"Old Project\"}")
    let v1 = try! Data(contentsOf: url)
    check((try? FirebaseProjectConfig.load(from: url)) == [entry("old-proj", "Old Project")], "version 1 reads as a one-project list")
    check((try! Data(contentsOf: url)) == v1, "reading a version 1 file never rewrites it")
    write("{\"version\":1,\"projectId\":\"old-proj\"}")
    check((try? FirebaseProjectConfig.load(from: url)) == [entry("old-proj")], "version 1 without a name falls back to the ID")
    write("{\"version\":1,\"projectId\":\"  \",\"displayName\":\"x\"}")
    check(configError { try FirebaseProjectConfig.load(from: url) } == .corrupt("projectId is empty"), "version 1 with a blank ID is corrupt")
    write("{\"version\":1,\"projectId\":\"old-proj\",\"displayName\":\"Old\"}")
    try! FirebaseProjectConfig.save((try! FirebaseProjectConfig.load(from: url)) + [entry("new-proj")], to: url)
    let upgraded = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    check(upgraded["version"] as? Int == 2 && (upgraded["projects"] as? [Any])?.count == 2, "the next save writes version 2")

    // Damaged files are errors, and reading never modifies them.
    let notValid = FirebaseConfigError.corrupt("not a valid project list")
    for (label, text) in [("garbage", "{not json"), ("array root", "[]"), ("no version", "{\"projects\":[]}"),
                          ("string version", "{\"version\":\"2\",\"projects\":[]}"), ("boolean version", "{\"version\":true,\"projects\":[]}"),
                          ("projects not an array", "{\"version\":2,\"projects\":{}}"), ("no projects key", "{\"version\":2}"),
                          ("entry not an object", "{\"version\":2,\"projects\":[\"x\"]}"), ("entry without an ID", "{\"version\":2,\"projects\":[{\"displayName\":\"x\"}]}"),
                          ("version 1 without an ID", "{\"version\":1,\"displayName\":\"x\"}")] {
        write(text)
        check(configError { try FirebaseProjectConfig.load(from: url) } == notValid, "\(label) is corrupt")
    }
    write("{\"version\":2,\"projects\":[{\"projectId\":\"ok\"},{\"projectId\":\"  \"}]}")
    check(configError { try FirebaseProjectConfig.load(from: url) } == .corrupt("projectId is empty"), "a blank project ID in the list is corrupt")
    write("{\"version\":3,\"projects\":[]}")
    check(configError { try FirebaseProjectConfig.load(from: url) } == .unsupportedVersion(3), "newer version is unsupported")
    write("{\"version\":3,\"somethingNew\":true}")
    check(configError { try FirebaseProjectConfig.load(from: url) } == .unsupportedVersion(3), "newer schema without our fields reports its version")
    write("{\"version\":0}")
    check(configError { try FirebaseProjectConfig.load(from: url) } == .unsupportedVersion(0), "version 0 is unsupported")
    let before = try! Data(contentsOf: url)
    _ = try? FirebaseProjectConfig.load(from: url)
    check((try! Data(contentsOf: url)) == before, "load never rewrites a bad file")

    // Unreadable (a directory where the file should be) is distinct from absent.
    let asDirectory = dir.appendingPathComponent("dir-config.json")
    try! FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)
    if case .unreadable? = configError({ try FirebaseProjectConfig.load(from: asDirectory) }) {} else {
        check(false, "a directory in place of the file is .unreadable, not absent")
    }
}

func testSaveFailureKeepsPreviousFile() {
    let dir = makeTempDirectory()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
    let url = dir.appendingPathComponent("config.json")
    try! FirebaseProjectConfig.save([entry("keep-me", "Keep Me")], to: url)
    let original = try! Data(contentsOf: url)

    // Parent directory is read-only: the temp file can't be created.
    try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    if case .writeFailed? = configError({ try FirebaseProjectConfig.save([entry("other")], to: url); return nil }) {} else {
        check(false, "save into a read-only directory throws writeFailed")
    }
    check((try! Data(contentsOf: url)) == original, "failed save leaves the previous file byte-for-byte intact")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    check(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []) == ["config.json"], "failed save leaves no temp file")

    // A path component that is a regular file can't become a directory.
    let blocked = dir.appendingPathComponent("config.json/nested/config.json")
    if case .writeFailed? = configError({ try FirebaseProjectConfig.save([entry("x")], to: blocked); return nil }) {} else {
        check(false, "save under a regular file throws writeFailed")
    }
    check((try! Data(contentsOf: url)) == original, "still intact after blocked-path failure")

    // Refuses to persist a blank project ID anywhere in the list.
    check(configError({ try FirebaseProjectConfig.save([entry("fine"), FirebaseProjectEntry(projectId: " ", displayName: "n")], to: url); return nil }) != nil, "blank projectId refused")
    check((try! Data(contentsOf: url)) == original, "refused save changed nothing")
}

func testConcurrentWriters() {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("config.json")
    try! FirebaseProjectConfig.save([entry("seed-a"), entry("seed-b")], to: url)

    let writers = 8, rounds = 60
    let lock = NSLock()
    nonisolated(unsafe) var readFailures = 0
    nonisolated(unsafe) var writeFailures = 0
    nonisolated(unsafe) var finished = 0
    let group = DispatchGroup()
    for w in 0..<writers {
        group.enter()
        DispatchQueue.global().async {
            for r in 0..<rounds {
                do { try FirebaseProjectConfig.save([entry("writer-\(w)-\(r)-a", "Writer \(w)"), entry("writer-\(w)-\(r)-b")], to: url) } catch { lock.lock(); writeFailures += 1; lock.unlock() }
            }
            lock.lock(); finished += 1; lock.unlock()
            group.leave()
        }
    }
    group.enter()
    DispatchQueue.global().async {
        while true {
            lock.lock(); let done = finished == writers; lock.unlock()
            // Every read, mid-storm, must see one writer's complete two-project list: never torn, never missing.
            do {
                let list = try FirebaseProjectConfig.load(from: url)
                let complete = list.count == 2 && list[0].projectId.hasSuffix("-a") && list[1].projectId.hasSuffix("-b")
                    && list[0].projectId.dropLast(2) == list[1].projectId.dropLast(2)
                if !complete { lock.lock(); readFailures += 1; lock.unlock() }
            } catch { lock.lock(); readFailures += 1; lock.unlock() }
            if done { break }
        }
        group.leave()
    }
    group.wait()
    check(writeFailures == 0, "no writer failed under contention (\(writeFailures))")
    check(readFailures == 0, "readers never saw a torn or mixed list (\(readFailures))")
    let final = try? FirebaseProjectConfig.load(from: url)
    check(final?.count == 2 && final?[0].projectId.hasPrefix("writer-") == true && final?[0].projectId.hasSuffix("-\(rounds - 1)-a") == true,
          "final file is a complete last write of one writer: \(String(describing: final))")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    check(leftovers == ["config.json"], "no temp files left after the storm: \(leftovers)")
}

// MARK: - Store / observer

@MainActor
func eventually(_ message: String, line: Int = #line, _ condition: () -> Bool) async {
    let reached = await waitUntil(condition)
    check(reached, message, line: line)
}

@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

@MainActor
func testStore() async {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("firebase/config.json")

    // Two stores stand in for two widget libraries / windows: they share only the file.
    let a = FirebaseProjectStore(url: url, interval: 0.05)
    let b = FirebaseProjectStore(url: url, interval: 0.05)
    a.start(); b.start()
    check(a.state == .empty && b.state == .empty && a.projects.isEmpty, "absent file → .empty")
    check(a.isRunning, "started store is running")

    try! a.save([entry("proj-1", "Project One")])
    check(a.state == .listed([entry("proj-1", "Project One")]) && a.projects.map(\.projectId) == ["proj-1"], "save adopts immediately in the saving store")
    await eventually("other store sees the new list through the file within 2s") { b.state == .listed([entry("proj-1", "Project One")]) }

    // Atomic replacement by an outside writer, adding a project.
    try! FirebaseProjectConfig.save([entry("proj-1", "Project One"), entry("proj-2", "Project Two")], to: url)
    await eventually("both stores converge on an external atomic replacement") { a.projects.map(\.projectId) == ["proj-1", "proj-2"] && b.projects.map(\.projectId) == ["proj-1", "proj-2"] }

    // Unchanged file: state is not republished.
    nonisolated(unsafe) var changes = 0
    func track() {
        withObservationTracking { _ = b.state } onChange: { changes += 1 }
    }
    track()
    try? await Task.sleep(nanoseconds: 400_000_000)
    check(changes == 0, "polling an unchanged file doesn't touch observers (\(changes))")
    b.reload()
    check(changes == 0, "reload of identical content doesn't change state")

    // An invalid external edit becomes .invalid and is left alone; saving a list repairs it.
    try! "oops".write(to: url, atomically: true, encoding: .utf8)
    await eventually("corrupt edit → .invalid") { if case .invalid = a.state { return true } else { return false } }
    check((try! String(contentsOf: url, encoding: .utf8)) == "oops", "invalid file is not overwritten by reading")
    check(a.projects.isEmpty, "an invalid file lists no projects")
    try! b.save([entry("proj-3")])
    await eventually("explicit save repairs it for everyone") { a.projects.map(\.projectId) == ["proj-3"] }

    // A version 1 file written by plugin 0.1.0 shows as one project and stays version 1.
    let v1 = "{\"version\":1,\"projectId\":\"legacy\",\"displayName\":\"Legacy\"}"
    try! v1.write(to: url, atomically: true, encoding: .utf8)
    await eventually("a version 1 file reads as one project") { a.state == .listed([entry("legacy", "Legacy")]) }
    try? await Task.sleep(nanoseconds: 200_000_000)
    check((try! String(contentsOf: url, encoding: .utf8)) == v1, "following a version 1 file never rewrites it")

    // An emptied list and a removed file are both "no projects".
    try! a.save([])
    await eventually("an empty saved list → .empty") { b.state == .empty }
    check(FileManager.default.fileExists(atPath: url.path), "the empty list is a real file")
    try! b.save([entry("again")])
    try! FileManager.default.removeItem(at: url)
    await eventually("deleted file → .empty") { a.state == .empty }

    // stop() ends observation.
    a.stop()
    check(!a.isRunning, "stopped store is not running")
    try! FirebaseProjectConfig.save([entry("after-stop")], to: url)
    try? await Task.sleep(nanoseconds: 300_000_000)
    check(a.state == .empty, "a stopped store no longer follows the file")
    a.start()
    check(a.projects.map(\.projectId) == ["after-stop"], "start() re-reads on activation")
    a.stop(); b.stop()

    // save() failing leaves state alone.
    let blocker = dir.appendingPathComponent("blocker")
    try! "file".write(to: blocker, atomically: true, encoding: .utf8)
    let c = FirebaseProjectStore(url: blocker.appendingPathComponent("config.json"), interval: 0.05)
    var threw = false
    do { try c.save([entry("x")]) } catch { threw = true }
    check(threw && c.state == .empty, "failed save throws and leaves state unchanged")
}

// MARK: - Parser

func parserError(_ text: String) -> FirebaseProjectListError? {
    do { _ = try FirebaseProjectParser.parseProjects(Data(text.utf8)); return nil } catch { return error as? FirebaseProjectListError }
}

func testParser() {
    let projects = try! FirebaseProjectParser.parseProjects(Data(envelope([("a-1", "Alpha"), ("b-2", nil), ("c-3", "")]).utf8))
    check(projects == [
        FirebaseProject(projectId: "a-1", displayName: "Alpha"),
        FirebaseProject(projectId: "b-2", displayName: "b-2"),
        FirebaseProject(projectId: "c-3", displayName: "c-3"),
    ], "names parsed; missing or blank display name falls back to the ID: \(projects)")
    check((try? FirebaseProjectParser.parseProjects(Data(envelope([]).utf8))) == [], "empty result is an empty list")
    let dupes = try! FirebaseProjectParser.parseProjects(Data(envelope([("a", "First"), ("a", "Second")]).utf8))
    check(dupes == [FirebaseProject(projectId: "a", displayName: "First")], "projects are identified by projectId")

    check(parserError("") == .malformedOutput("not JSON"), "empty output")
    check(parserError("Preparing the list…") == .malformedOutput("not JSON"), "spinner text is not JSON")
    check(parserError("[]") == .malformedOutput("expected a JSON object"), "array root")
    check(parserError("{\"status\":\"success\"}") == .malformedOutput("missing result array"), "no result")
    check(parserError("{\"status\":\"success\",\"result\":{}}") == .malformedOutput("missing result array"), "result not an array")
    check(parserError("{\"status\":\"success\",\"result\":[{\"displayName\":\"x\"}]}") == .malformedOutput("a project has no projectId"), "entry without projectId")
    check(parserError("{\"status\":\"success\",\"result\":[\"nope\"]}") == .malformedOutput("a project has no projectId"), "entry not an object")
    check(parserError("{\"status\":\"error\",\"error\":\"Boom\"}") == .cliFailed("Boom"), "error envelope surfaces its message")
}

// MARK: - Lister

func listError(_ result: FirebaseShellResult) async -> FirebaseProjectListError? {
    do { _ = try await FirebaseProjectLister.list(run: FakeShell(result).runner); return nil } catch { return error as? FirebaseProjectListError }
}

func testLister() async {
    let shell = FakeShell(ok(envelope([("p", "P")])))
    let listed = try? await FirebaseProjectLister.list(run: shell.runner)
    check(listed == [FirebaseProject(projectId: "p", displayName: "P")], "lists via the shell")
    check(shell.calls == [FirebaseProjectLister.command], "the lister runs exactly its command: \(shell.calls)")
    check(FirebaseProjectLister.command.hasSuffix("firebase projects:list --json --non-interactive"), "and it ends with the documented CLI call")

    // A non-zero exit beats parseable stdout.
    await checkA(await listError(FirebaseShellResult(stdout: envelope([("p", "P")]), stderr: "boom", exitCode: 1)) == .cliFailed("boom"), "non-zero exit wins over valid stdout")
    await checkA(await listError(FirebaseShellResult(stdout: "", stderr: "zsh: command not found: firebase", exitCode: 127)) == .cliMissing, "127 → CLI missing")
    await checkA(await listError(FirebaseShellResult(stdout: "", stderr: "zsh: command not found: firebase", exitCode: 1)) == .cliMissing, "command-not-found text → CLI missing")
    await checkA(await listError(FirebaseShellResult(stdout: "{\"status\":\"error\",\"error\":\"Failed to authenticate, have you run firebase login?\"}", stderr: "", exitCode: 1))
          == .notAuthenticated("Failed to authenticate, have you run firebase login?"), "unauthenticated → login guidance")
    await checkA(await listError(FirebaseShellResult(stdout: "", stderr: "Error: Authentication Error: Your credentials are no longer valid. Please run firebase login --reauth", exitCode: 1)) != nil, "expired credentials classified")
    if case .notAuthenticated? = await listError(FirebaseShellResult(stdout: "", stderr: "Your credentials are no longer valid. Please run firebase login --reauth", exitCode: 1)) {} else {
        check(false, "expired credentials → notAuthenticated")
    }
    await checkA(await listError(FirebaseShellResult(stdout: "{\"status\":\"error\",\"error\":\"Failed to list Firebase projects. See firebase-debug.log for more info.\"}", stderr: "", exitCode: 1))
          == .cliFailed("Failed to list Firebase projects. See firebase-debug.log for more info."), "JSON error message preferred")
    await checkA(await listError(FirebaseShellResult(stdout: "", stderr: "", exitCode: 3)) == .cliFailed("exit code 3"), "bare exit code")
    await checkA(await listError(ok("not json")) == .malformedOutput("not JSON"), "exit 0 with garbage")
    await checkA(await listError(ok("{\"status\":\"success\",\"result\":[{}]}")) == .malformedOutput("a project has no projectId"), "exit 0 with bad entry")

    let timeoutShell = FakeShell(ok(""))
    timeoutShell.error = NSError(domain: "shell", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out"])
    do { _ = try await FirebaseProjectLister.list(run: timeoutShell.runner); check(false, "shell error should throw") }
    catch { check((error as? FirebaseProjectListError) == .shellFailed("timed out"), "shell service failure wrapped: \(error)") }

    for error in [FirebaseProjectListError.cliMissing, .notAuthenticated("x")] {
        let text = error.localizedDescription
        check(text.contains("firebase-setup") || text.contains("firebase login"), "error points to setup/login: \(text)")
    }
}

// MARK: - Picker model

@MainActor
func testPickerModel() async {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("config.json")
    func makeStore(saved: [FirebaseProjectEntry]) -> FirebaseProjectStore {
        try? FileManager.default.removeItem(at: url)
        if !saved.isEmpty { try! FirebaseProjectConfig.save(saved, to: url) }
        let store = FirebaseProjectStore(url: url, interval: 0.05)
        store.reload()
        return store
    }
    func saved() -> [FirebaseProjectEntry] { (try? FirebaseProjectConfig.load(from: url)) ?? [] }
    let alpha = project("alpha-1", "Alpha App"), beta = project("beta-2", "Beta Service"), gamma = project("gamma-3", "Gamma")
    let list = envelope([("alpha-1", "Alpha App"), ("beta-2", "Beta Service"), ("gamma-3", "Gamma")])
    func row(_ p: FirebaseProject, checked: Bool, listed: Bool = true) -> FirebaseProjectPickerModel.Row {
        .init(project: p, isChecked: checked, isListedByCLI: listed)
    }

    // Before listing: the saved projects only, checked. After: CLI order, then saved projects the CLI didn't return.
    let store = makeStore(saved: [entry("alpha-1", "Alpha App"), entry("legacy", "Legacy Project")])
    let shell = FakeShell(ok(list))
    let model = FirebaseProjectPickerModel(run: shell.runner, store: store)
    check(model.phase == .idle && !model.hasListed, "starts idle")
    check(model.rows == [row(alpha, checked: true, listed: false), row(project("legacy", "Legacy Project"), checked: true, listed: false)], "before listing, only saved projects, checked: \(model.rows)")
    await model.refresh()
    check(model.phase == .loaded && model.hasListed, "loaded: \(model.phase)")
    check(model.rows == [row(alpha, checked: true), row(beta, checked: false), row(gamma, checked: false), row(project("legacy", "Legacy Project"), checked: true, listed: false)],
          "CLI order, saved checked, saved-but-unlisted last: \(model.rows)")
    model.query = "BETA"; check(model.filteredRows.map(\.id) == ["beta-2"], "search by name, case-insensitive")
    model.query = "alpha-1"; check(model.filteredRows.map(\.id) == ["alpha-1"], "search by ID")
    model.query = "legacy"; check(model.filteredRows.map(\.id) == ["legacy"], "search reaches the not-listed row")
    model.query = "zzz"; check(model.filteredRows.isEmpty, "no match")
    model.query = ""; check(model.filteredRows.count == 4, "cleared query shows all")
    await model.refresh()
    check(shell.calls.count == 2, "refresh re-runs the CLI")

    // Checks survive a refresh; toggling an unknown ID does nothing.
    model.toggle("beta-2"); model.toggle("nope")
    await model.refresh()
    check(model.rows.first { $0.id == "beta-2" }?.isChecked == true && model.rows.count == 4, "checks survive a refresh, unknown toggles are ignored")

    // Save: still-checked saved projects keep their order, unchecked ones go, new ones are appended.
    model.toggle("legacy")
    check(saved().map(\.projectId) == ["alpha-1", "legacy"], "nothing is written before saving")
    check(model.save(), "save succeeds")
    check(saved() == [entry("alpha-1", "Alpha App"), entry("beta-2", "Beta Service")], "saved list: \(saved())")
    check(store.projects.map(\.projectId) == ["alpha-1", "beta-2"], "store adopts the saved list")
    check(model.isFinished && !model.save(), "a finished window can't save again")

    // Saved order is kept; new checks follow in CLI order, not click order.
    let ordered = makeStore(saved: [entry("gamma-3", "Gamma"), entry("alpha-1", "Alpha App")])
    let m2 = FirebaseProjectPickerModel(run: FakeShell(ok(list)).runner, store: ordered)
    await m2.refresh(); m2.toggle("beta-2")
    check(m2.save() && saved().map(\.projectId) == ["gamma-3", "alpha-1", "beta-2"], "saved order kept, new project appended: \(saved().map(\.projectId))")
    let fresh = makeStore(saved: [])
    let m3 = FirebaseProjectPickerModel(run: FakeShell(ok(list)).runner, store: fresh)
    await m3.refresh(); m3.toggle("gamma-3"); m3.toggle("alpha-1")
    check(m3.save() && saved().map(\.projectId) == ["alpha-1", "gamma-3"], "new projects follow the CLI's order, not click order: \(saved().map(\.projectId))")

    // A saved project takes the CLI's current display name.
    let renamed = makeStore(saved: [entry("alpha-1", "Old Name")])
    let m4 = FirebaseProjectPickerModel(run: FakeShell(ok(list)).runner, store: renamed)
    await m4.refresh()
    check(m4.save() && saved() == [entry("alpha-1", "Alpha App")], "display name refreshed from the CLI: \(saved())")

    // Cancel: no write, and a late result is dropped.
    let keep = makeStore(saved: [entry("alpha-1", "Alpha App")])
    let slow = FakeShell(ok(list)); slow.delayNanos = 300_000_000
    let cancelled = FirebaseProjectPickerModel(run: slow.runner, store: keep)
    let before = try! Data(contentsOf: url)
    let pending = Task { await cancelled.refresh() }
    try? await Task.sleep(nanoseconds: 50_000_000)
    check(cancelled.phase == .loading, "slow listing is loading")
    cancelled.toggle("alpha-1")
    cancelled.cancel()
    await pending.value
    check(cancelled.phase == .loading && !cancelled.hasListed, "late result after cancel doesn't change state: \(cancelled.phase)")
    check(!cancelled.save(), "cancelled window refuses to save")
    check((try! Data(contentsOf: url)) == before && keep.projects.map(\.projectId) == ["alpha-1"], "cancel leaves the config unchanged")

    // Only one request at a time.
    let counting = FakeShell(ok(list)); counting.delayNanos = 200_000_000
    let busy = FirebaseProjectPickerModel(run: counting.runner, store: keep)
    async let first: Void = busy.refresh()
    try? await Task.sleep(nanoseconds: 30_000_000)
    async let second: Void = busy.refresh()
    async let third: Void = busy.refresh()
    _ = await (first, second, third)
    check(counting.calls.count == 1, "overlapping refreshes run the CLI once (\(counting.calls.count))")
    check(busy.phase == .loaded, "and still end loaded")

    // CLI failure: saved projects stay visible and can be unchecked, which saves an empty list; retry works.
    let down = makeStore(saved: [entry("alpha-1", "Alpha App")])
    let flaky = FakeShell(FirebaseShellResult(stdout: "", stderr: "zsh: command not found: firebase", exitCode: 127))
    let m5 = FirebaseProjectPickerModel(run: flaky.runner, store: down)
    await m5.refresh()
    if case .failed(let message) = m5.phase { check(message.contains("firebase-setup"), "missing CLI points to setup: \(message)") }
    else { check(false, "failed phase expected, got \(m5.phase)") }
    check(m5.rows == [row(alpha, checked: true, listed: false)] && !m5.hasListed, "saved projects stay visible while the CLI fails: \(m5.rows)")
    m5.toggle("alpha-1")
    check(m5.save() && saved().isEmpty && down.state == .empty && FileManager.default.fileExists(atPath: url.path), "unchecking everything saves an empty list")
    flaky.result = ok(list)
    let m6 = FirebaseProjectPickerModel(run: flaky.runner, store: down)
    await m6.refresh()
    check(m6.phase == .loaded && m6.rows.count == 3 && m6.rows.allSatisfy { !$0.isChecked }, "retry after failure loads, nothing checked")
    let retrying = FirebaseProjectPickerModel(run: FakeShell(FirebaseShellResult(stdout: "", stderr: "", exitCode: 2)).runner, store: down)
    await retrying.refresh()
    if case .failed = retrying.phase {} else { check(false, "exit 2 → failed") }
    flaky.result = ok(list)

    // Save failure keeps the window open and the saved list intact.
    let blocker = dir.appendingPathComponent("blocker")
    try! "file".write(to: blocker, atomically: true, encoding: .utf8)
    let brokenStore = FirebaseProjectStore(url: blocker.appendingPathComponent("config.json"), interval: 0.05)
    _ = makeStore(saved: [entry("existing")])
    let saving = FirebaseProjectPickerModel(run: FakeShell(ok(list)).runner, store: brokenStore)
    await saving.refresh(); saving.toggle("alpha-1")
    check(!saving.save(), "failed save returns false")
    check(saving.saveError?.contains("Couldn't save") == true, "save error surfaced: \(String(describing: saving.saveError))")
    check(!saving.isFinished, "window stays open after a failed save so the user can retry")
    check(brokenStore.state == .empty && saved().map(\.projectId) == ["existing"], "previous list retained")

    // Empty CLI list with nothing saved is a loaded-but-empty state, not an error.
    let empty = FirebaseProjectPickerModel(run: FakeShell(ok(envelope([]))).runner, store: makeStore(saved: []))
    await empty.refresh()
    check(empty.phase == .loaded && empty.rows.isEmpty && empty.filteredRows.isEmpty, "empty list")
}

// MARK: - Product catalog

func testProductCatalog() {
    check(FirebaseProduct.all.map(\.id) == ["auth", "analytics", "firestore", "crashlytics"], "exactly the four released products")
    check(FirebaseProduct.all.map(\.widgetId) == ["firebase-auth", "firebase-analytics", "firebase-firestore", "firebase-crashlytics"], "widget IDs")
    check(FirebaseProduct.all.map(\.title) == ["Firebase Authentication", "Firebase Analytics", "Firebase Firestore", "Firebase Crashlytics"], "titles")
    check(Set(FirebaseProduct.all.map(\.widgetId)).count == 4 && Set(FirebaseProduct.all.map(\.consolePath)).count == 4, "IDs and routes are unique")

    let base = "https://console.firebase.google.com/project/my-app/"
    check(FirebaseProduct.auth.consoleURL(projectId: "my-app")?.absoluteString == base + "authentication/users", "auth route")
    check(FirebaseProduct.analytics.consoleURL(projectId: "my-app")?.absoluteString == base + "analytics/overview", "analytics route")
    check(FirebaseProduct.firestore.consoleURL(projectId: "my-app")?.absoluteString == base + "firestore", "firestore route")
    check(FirebaseProduct.crashlytics.consoleURL(projectId: "my-app")?.absoluteString == base + "crashlytics", "crashlytics route")

    // A hand-edited project ID can't redirect the page elsewhere.
    for hostile in ["a/b", "a?x=1", "a#frag", "../other", "a b", "dom.com:proj", "ünï"] {
        let url = FirebaseProduct.firestore.consoleURL(projectId: hostile)
        check(url?.host == "console.firebase.google.com" && url?.query == nil && url?.fragment == nil, "stays on the Console for \(hostile): \(String(describing: url))")
        let parts = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath.split(separator: "/").map(String.init) } ?? []
        check(parts.count == 3 && parts[0] == "project" && parts[2] == "firestore", "project ID is one path component for \(hostile): \(parts)")
    }
    check(FirebaseProduct.auth.consoleURL(projectId: "  my-app ")?.absoluteString == base + "authentication/users", "ID trimmed")
    check(FirebaseProduct.auth.consoleURL(projectId: "") == nil && FirebaseProduct.auth.consoleURL(projectId: "  ") == nil, "blank ID → no URL")

    // Navigate only when the project really changes.
    let p = FirebaseProduct.crashlytics
    check(p.navigationTarget(selected: nil, loaded: nil) == nil, "no selection → leave the page alone")
    check(p.navigationTarget(selected: nil, loaded: "old") == nil, "selection removed → keep showing what's loaded")
    check(p.navigationTarget(selected: "p1", loaded: nil)?.absoluteString.contains("/project/p1/crashlytics") == true, "first selection navigates")
    check(p.navigationTarget(selected: "p1", loaded: "p1") == nil, "same project → don't reload (browsing survives)")
    check(p.navigationTarget(selected: "p2", loaded: "p1")?.absoluteString.contains("/project/p2/crashlytics") == true, "changed project navigates to this product's page")
}

// MARK: - Plugin layout and source sync

func testWidgetLayout() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fm = FileManager.default
    let widgetDirs = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("widgets").path)) ?? []).filter { $0.hasPrefix("firebase-") }.sorted()
    check(widgetDirs == FirebaseProduct.all.map(\.widgetId).sorted(), "one widget folder per catalog product, no extras: \(widgetDirs)")
    let shared = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("shared").path)) ?? []).filter { $0.hasSuffix(".swift") }.sorted()
    check(shared == ["FirebaseBrand.swift", "FirebaseConsoleWidget.swift", "FirebaseProduct.swift", "FirebaseProjectConfig.swift", "FirebaseProjectPicker.swift", "FirebaseTabs.swift"], "shared sources: \(shared)")
    for product in FirebaseProduct.all {
        let sources = root.appendingPathComponent("widgets/\(product.widgetId)/Sources")
        for name in shared {
            let copy = try? String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            let original = try? String(contentsOf: root.appendingPathComponent("shared/\(name)"), encoding: .utf8)
            check(copy != nil && original != nil && copy!.hasSuffix(original!) && copy!.hasPrefix("// GENERATED by scripts/sync-widget-sources.py"),
                  "\(product.widgetId) carries an up-to-date copy of \(name)")
        }
        // The installer copies Sources on its own: nothing may point outside it.
        let wrapper = (try? String(contentsOf: sources.appendingPathComponent("Widget.swift"), encoding: .utf8)) ?? ""
        check(wrapper.contains("FirebaseConsoleWidget(product: .\(product.id))"), "\(product.widgetId) registers its own product")
        check(wrapper.contains("@_cdecl(\"work42_widget_sdk_version\")") && wrapper.contains("@_cdecl(\"work42_widget_main\")"), "\(product.widgetId) exports both loader symbols")
        check(((try? fm.destinationOfSymbolicLink(atPath: sources.path)) == nil) && ((try? fm.contentsOfDirectory(atPath: sources.path)) ?? []).allSatisfy {
            (try? fm.destinationOfSymbolicLink(atPath: sources.appendingPathComponent($0).path)) == nil }, "\(product.widgetId) Sources has no symlinks")
    }
}

func testSyncScriptDetectsDrift() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let scratch = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let copy = scratch.appendingPathComponent("firebase")
    try! FileManager.default.copyItem(at: root, to: copy)
    func runSync(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [copy.appendingPathComponent("scripts/sync-widget-sources.py").path] + args
        p.standardOutput = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
        return p.terminationStatus
    }
    check(runSync(["--check"]) == 0, "committed copies are in sync")
    let victim = copy.appendingPathComponent("widgets/firebase-firestore/Sources/FirebaseProduct.swift")
    try! (try! String(contentsOf: victim, encoding: .utf8) + "// drift\n").write(to: victim, atomically: true, encoding: .utf8)
    check(runSync(["--check"]) == 1, "--check fails on a stale copy")
    check(runSync(["--check"]) == 1 && (try! String(contentsOf: victim, encoding: .utf8)).hasSuffix("// drift\n"), "--check never writes")
    check(runSync([]) == 0 && runSync(["--check"]) == 0, "running the script repairs the drift")
    try! FileManager.default.removeItem(at: copy.appendingPathComponent("widgets/firebase-auth/Sources/FirebaseProjectConfig.swift"))
    check(runSync(["--check"]) == 1, "--check fails on a missing copy")
    _ = runSync([])
    try! "// GENERATED by scripts/sync-widget-sources.py from firebase/shared/Gone.swift\n".write(
        to: copy.appendingPathComponent("widgets/firebase-auth/Sources/FirebaseGone.swift"), atomically: true, encoding: .utf8)
    check(runSync(["--check"]) == 1, "--check fails on an orphaned generated copy")
}

// MARK: - Skills

/// First capture group of every match of `pattern` in `text`.
func captures(_ pattern: String, in text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
}

func testSkills() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fm = FileManager.default
    func read(_ relative: String) -> String? { try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8) }
    func frontmatter(_ text: String) -> [String: String]? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return nil }
        var out: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            out[String(line[..<colon])] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }
    /// The text of the section that starts at `## Prerequisites` up to the next `## ` heading.
    func prerequisites(_ text: String) -> (position: Int, body: String)? {
        let lines = text.components(separatedBy: "\n")
        let headings = lines.enumerated().filter { $0.element.hasPrefix("## ") }
        guard let index = headings.firstIndex(where: { $0.element == "## Prerequisites" }) else { return nil }
        let start = headings[index].offset
        let end = index + 1 < headings.count ? headings[index + 1].offset : lines.count
        return (index, lines[start..<end].joined(separator: "\n"))
    }

    let skillDirs = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("skills").path)) ?? []).sorted()
    let expected = (["firebase-setup", "using-firebase"] + FirebaseProduct.all.map { "firebase-\($0.id)" }).sorted()
    check(skillDirs == expected, "skills are setup, index and the four released products only: \(skillDirs)")

    var documents: [(path: String, text: String)] = []
    for dir in expected { if let t = read("skills/\(dir)/SKILL.md") { documents.append(("skills/\(dir)", t)) } else { check(false, "skills/\(dir)/SKILL.md exists") } }
    for product in FirebaseProduct.all { if let t = read("widgets/\(product.widgetId)/SKILL.md") { documents.append(("widgets/\(product.widgetId)", t)) } else { check(false, "widget skill for \(product.widgetId) exists") } }

    var commands = Set<String>()
    for (path, text) in documents {
        let isWidget = path.hasPrefix("widgets/")
        let name = String(path.split(separator: "/").last!)
        let fm = frontmatter(text)
        check(fm?["name"] == (isWidget ? "widget-\(name)" : name), "\(path): frontmatter name matches (\(fm?["name"] ?? "none"))")
        check((fm?["description"] ?? "").count > 40, "\(path): has a real description")
        check(!text.contains("Set Project"), "\(path): no leftover single-project wording")
        if name != "firebase-setup" {
            check(text.contains("Exactly one: use it. Several: use the one the user named, otherwise ask which."), "\(path): states the one/several/none project rule")
        }
        check(text.contains("~/.work42/firebase/config.json") || text.contains("$HOME/.work42/firebase/config.json"), "\(path): names the shared config file")

        // Skills that depend on the CLI start with Prerequisites that end in the setup fallback.
        if name != "firebase-setup" && name != "using-firebase" {
            let heading = text.components(separatedBy: "\n").first { $0.hasPrefix("## ") }
            check(heading == "## Prerequisites", "\(path): Prerequisites is the first section (\(heading ?? "none"))")
            let prereq = prerequisites(text)
            check(prereq?.body.contains("firebase-setup") == true && prereq?.body.contains("command -v firebase") == true, "\(path): Prerequisites check the CLI and fall back to firebase-setup")
        }
        if !isWidget && name != "firebase-setup" && name != "using-firebase" {
            check(text.contains("--project \"$project\""), "\(path): passes the selected project explicitly")
            check(text.contains("firebase <command> --help") || text.contains("--help"), "\(path): tells the agent to check installed help")
            check(text.contains("## References") && text.contains("](https://"), "\(path): links official docs")
        }
        if isWidget { check(text.contains("firebase-\(name.dropFirst("firebase-".count))` skill"), "\(path): points at its product skill") }

        // `firebase use` and .firebaserc may only be mentioned as things never to do.
        for line in text.components(separatedBy: "\n") where line.contains("firebase use") || line.contains(".firebaserc") {
            let lowered = line.lowercased()
            check(lowered.contains("never") || lowered.contains("not ") || lowered.contains("repo's own"), "\(path): '\(line.prefix(70))…' only forbids it")
        }
        // Links are https; no credentials-handling advice.
        for link in captures(#"\]\((http[^)]*)\)"#, in: text) { check(link.hasPrefix("https://"), "\(path): link is https: \(link)") }
        check(!text.contains("FIREBASE_TOKEN") || text.lowercased().contains("never"), "\(path): doesn't recommend token auth")
        // Commands named in a prohibition ("Do not try `firebase analytics:...`") are not claims of support.
        for line in text.components(separatedBy: "\n") where !line.contains("Do not") {
            for command in captures(#"`firebase ([a-z][a-z:]*)"#, in: line) { commands.insert(command) }
        }
    }

    // Each widget skill's Console path agrees with the catalog.
    for product in FirebaseProduct.all {
        check(read("widgets/\(product.widgetId)/SKILL.md")?.contains("/project/<projectId>/\(product.consolePath)") == true, "\(product.widgetId) skill documents the catalog route \(product.consolePath)")
    }
    // The product skills may not claim analytics CLI commands (there are none) or a Crashlytics issue reader.
    for line in (read("skills/firebase-analytics/SKILL.md") ?? "").components(separatedBy: "\n") where line.contains("firebase analytics:") {
        check(line.contains("Do not"), "analytics skill mentions an analytics CLI command only to forbid it: \(line.prefix(60))")
    }
    check((read("skills/firebase-analytics/SKILL.md") ?? "").contains("no Analytics commands"), "analytics skill states the CLI gap")

    // Every command the skills mention exists in the installed CLI (skipped when firebase isn't installed).
    let which = Process(); which.executableURL = URL(fileURLWithPath: "/bin/sh"); which.arguments = ["-lc", "command -v firebase"]
    which.standardOutput = FileHandle.nullDevice; which.standardError = FileHandle.nullDevice
    try? which.run(); which.waitUntilExit()
    if which.terminationStatus == 0 {
        for command in commands.sorted() {
            // An unknown command still exits 0 with the general help, so require the command's own usage line.
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-lc", "firebase \(command) --help"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            try? p.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            check(p.terminationStatus == 0 && output.hasPrefix("Usage: firebase \(command)"), "skills mention `firebase \(command)` and the installed CLI knows it")
        }
        print("verified \(commands.count) CLI commands against the installed firebase")
    } else {
        print("skipped CLI command verification: firebase is not installed")
    }
}

// MARK: - Manifest and package contract

func testManifest() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fm = FileManager.default
    let yaml = (try? String(contentsOf: root.appendingPathComponent("plugin.yaml"), encoding: .utf8)) ?? ""
    // Top-level scalar keys only; the description is a folded block.
    var fields: [String: String] = [:]
    for line in yaml.components(separatedBy: "\n") where !line.hasPrefix(" ") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        fields[String(line[..<colon])] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
    check(fields["manifest_version"] == "2", "manifest v2")
    check(fields["name"] == "firebase" && fields["version"] == "0.2.0", "name and version 0.2.0 (\(fields["version"] ?? "none"))")
    check(fields["sdk_version"] == "2.3.1" && fields["sdk_abi"] == "12", "SDK 2.3.1 / ABI 12")
    check(fields["requires"] == "[]", "requires nothing")
    check(fields["global_skills"] == "using-firebase", "only the index skill is global")
    // No session type, workflow, intents, MCP or compiled hooks: the plugin only adds widgets and skills.
    for absent in ["session-types", "workflows", "intents", "mcp", "Sources", "tab-templates"] {
        check(!fm.fileExists(atPath: root.appendingPathComponent(absent).path), "no \(absent) contribution")
    }
    // Nothing that must be generated at install time is committed.
    let found = fm.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []
    check(!found.contains { $0.hasSuffix(".dylib") || $0.hasSuffix("widget.yaml") || $0.hasSuffix("firebase-debug.log") || $0.contains(".build/") }, "no build products committed")
    // The README documents every released widget and skill.
    let readme = (try? String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
    for product in FirebaseProduct.all {
        check(readme.contains("`\(product.widgetId)`") && readme.contains(product.title) && readme.contains("`firebase-\(product.id)`"), "README covers \(product.widgetId)")
    }
    check(readme.contains("~/.work42/firebase/config.json") && readme.contains("firebase login") && readme.contains("firebase-setup"), "README covers the config file and the two sign-ins")
}

// MARK: - Finding the CLI from the app's minimal shell

/// Runs `command` in a real /bin/sh with exactly `env`, like the Dock-launched app's shell: no ~/.zshrc, tiny PATH.
func realShell(env: [String: String]) -> FirebaseShellRunner {
    { command in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return FirebaseShellResult(stdout: stdout, stderr: stderr, exitCode: p.terminationStatus)
    }
}

func testCLIResolution() async {
    let home = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: home) }
    let fm = FileManager.default
    let marker = home.appendingPathComponent("nvm-was-sourced")
    let stubJSON = "{\"status\":\"success\",\"result\":[{\"projectId\":\"from-stub\",\"displayName\":\"From Stub\"}]}"

    func makeNvm(at dir: URL, script: String) {
        try! fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let stub = dir.appendingPathComponent("bin/firebase")
        try! "#!/bin/sh\necho '\(stubJSON)'\n".write(to: stub, atomically: true, encoding: .utf8)
        try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        try! script.write(to: dir.appendingPathComponent("nvm.sh"), atomically: true, encoding: .utf8)
    }
    let basePath = "/usr/bin:/bin"
    let nvmScript = "echo 'nvm banner noise'\ntouch '\(marker.path)'\nPATH=\"$NVM_DIR/bin:$PATH\"; export PATH\n"

    // 1. Installed through nvm, invisible to the app's PATH: found by the prelude (and the nvm noise is ignored).
    let nvm1 = home.appendingPathComponent("nvm1")
    makeNvm(at: nvm1, script: nvmScript)
    let found = try? await FirebaseProjectLister.list(run: realShell(env: ["HOME": home.path, "NVM_DIR": nvm1.path, "PATH": basePath]))
    check(found == [FirebaseProject(projectId: "from-stub", displayName: "From Stub")], "CLI under nvm is found from a minimal PATH: \(String(describing: found))")
    check(fm.fileExists(atPath: marker.path), "the prelude really sourced nvm.sh")

    // 2. Already on PATH: nvm is not touched.
    try? fm.removeItem(at: marker)
    let direct = try? await FirebaseProjectLister.list(run: realShell(env: ["HOME": home.path, "NVM_DIR": nvm1.path, "PATH": "\(nvm1.path)/bin:\(basePath)"]))
    check(direct?.first?.projectId == "from-stub", "CLI already on PATH works")
    check(!fm.fileExists(atPath: marker.path), "nvm.sh is not sourced when firebase is already on PATH")

    // 3. NVM_DIR unset: falls back to $HOME/.nvm.
    try? fm.removeItem(at: marker)
    let homeNvm = home.appendingPathComponent(".nvm")
    makeNvm(at: homeNvm, script: "touch '\(marker.path)'\nPATH=\"$HOME/.nvm/bin:$PATH\"; export PATH\n")
    let viaHome = try? await FirebaseProjectLister.list(run: realShell(env: ["HOME": home.path, "PATH": basePath]))
    check(viaHome?.first?.projectId == "from-stub" && fm.fileExists(atPath: marker.path), "NVM_DIR defaults to $HOME/.nvm")

    // 4. Really not installed: no nvm at all, an empty nvm dir, and an nvm.sh that fails and finds nothing → cliMissing.
    let emptyHome = makeTempDirectory(); defer { try? fm.removeItem(at: emptyHome) }
    let failing = emptyHome.appendingPathComponent("failing-nvm")
    try! fm.createDirectory(at: failing, withIntermediateDirectories: true)
    try! "echo oops >&2\nfalse\n".write(to: failing.appendingPathComponent("nvm.sh"), atomically: true, encoding: .utf8)
    for (label, env) in [("no nvm installed", ["HOME": emptyHome.path, "PATH": basePath]),
                         ("empty NVM_DIR", ["HOME": emptyHome.path, "NVM_DIR": emptyHome.path, "PATH": basePath]),
                         ("nvm.sh that fails", ["HOME": emptyHome.path, "NVM_DIR": failing.path, "PATH": basePath])] {
        do { _ = try await FirebaseProjectLister.list(run: realShell(env: env)); check(false, "\(label): should not find a CLI") }
        catch { check((error as? FirebaseProjectListError) == .cliMissing, "\(label) → cliMissing, got \(error)") }
    }

    // 5. Messages.
    let missing = FirebaseProjectListError.cliMissing.localizedDescription
    check(missing.contains("PATH") && missing.contains("nvm") && missing.contains("firebase-setup"), "missing-CLI message explains PATH/nvm and points to setup: \(missing)")
    check(!missing.contains("isn't installed"), "and doesn't claim the CLI isn't installed")

    // What the real CLI printed with an expired login (exit 2, generic JSON error, nothing about login).
    let expired = FirebaseShellResult(stdout: "{\n  \"status\": \"error\",\n  \"error\": \"Failed to list Firebase projects. See firebase-debug.log for more info.\"\n}\n",
                                      stderr: "- Preparing the list of your Firebase projects\n\u{2716} Preparing the list of your Firebase projects\n", exitCode: 2)
    do { _ = try await FirebaseProjectLister.list(run: FakeShell(expired).runner); check(false, "expired login should fail") }
    catch {
        let text = error.localizedDescription
        check((error as? FirebaseProjectListError) == .cliFailed("Failed to list Firebase projects. See firebase-debug.log for more info."), "expired login is a cliFailed with the CLI's own message")
        check(text.contains("firebase login --reauth") && text.contains("firebase-debug.log"), "expired login message gives the fix and keeps the CLI's text: \(text)")
    }
    let other = FirebaseProjectListError.cliFailed("Permission denied on project x").localizedDescription
    check(!other.contains("--reauth") && other.contains("Permission denied on project x"), "other CLI failures don't get the login hint: \(other)")
}

// MARK: - Brand icons

func testIcons() {
    let icons: [(name: String, data: Data)] = [
        ("auth", FirebaseBrand.authIconPNG), ("analytics", FirebaseBrand.analyticsIconPNG),
        ("firestore", FirebaseBrand.firestoreIconPNG), ("crashlytics", FirebaseBrand.crashlyticsIconPNG),
        ("firebase logomark", FirebaseBrand.firebaseMarkPNG),
    ]
    func be32(_ b: [UInt8], _ at: Int) -> Int { Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3]) }
    for (name, data) in icons {
        let bytes = [UInt8](data)
        check(bytes.count > 200 && Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "\(name): has the PNG signature (\(bytes.count) bytes)")
        guard bytes.count > 33 else { continue }
        check(String(decoding: bytes[12..<16], as: UTF8.self) == "IHDR", "\(name): starts with an IHDR chunk")
        check(be32(bytes, 16) == 64 && be32(bytes, 20) == 64, "\(name): is 64x64 (\(be32(bytes, 16))x\(be32(bytes, 20)))")
        check(bytes[24] == 8 && bytes[25] == 6, "\(name): 8-bit RGBA (colour type 6), got depth \(bytes[24]) type \(bytes[25])")

        // Real pixels: the circle's corners are transparent, its centre opaque (a white tile would fail this).
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            check(false, "\(name): decodes as an image"); continue
        }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let context = CGContext(data: &pixels, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * 64 + x) * 4 + 3] }
        check([alpha(0, 0), alpha(63, 0), alpha(0, 63), alpha(63, 63)] == [0, 0, 0, 0], "\(name): corners are transparent")
        let transparent = stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] == 0 }.count
        check(transparent > 200 && transparent < 64 * 64 - 800, "\(name): some transparency, not an empty image (\(transparent) transparent pixels)")
        if name != "firebase logomark" { check(alpha(32, 32) == 255, "\(name): centre is opaque") }
    }
    check(Set(icons.map(\.data)).count == 5, "the five images are all different")

    // Products carry their own icon.
    check(FirebaseProduct.auth.iconPNG == FirebaseBrand.authIconPNG && FirebaseProduct.analytics.iconPNG == FirebaseBrand.analyticsIconPNG
          && FirebaseProduct.firestore.iconPNG == FirebaseBrand.firestoreIconPNG && FirebaseProduct.crashlytics.iconPNG == FirebaseBrand.crashlyticsIconPNG,
          "each product exposes its own icon")
    check(Set(FirebaseProduct.all.map(\.iconPNG)).count == 4, "no two products share an icon")

    // The embedded files document where they came from.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let header = (try? String(contentsOf: root.appendingPathComponent("shared/FirebaseBrand.swift"), encoding: .utf8)) ?? ""
    for url in ["static/images/products/icons/build_auth.svg", "static/images/products/icons/run_analytics.svg",
                "static/images/products/icons/build_firestore.svg", "static/images/products/icons/run_crashlytics.svg",
                "static/downloads/brand-guidelines/SVG/logo-logomark.svg", "brand-guidelines"] {
        check(header.contains("firebase.google.com/" + url), "FirebaseBrand.swift cites \(url)")
    }
}

// MARK: - Tabs

func testTabs() {
    let listed = [entry("work42-dev", "Work42 Development"), entry("work42-prod", "Work42 Production"), entry("other-app", "Other App")]
    let base = "https://console.firebase.google.com/project/"

    // One tab per listed project, in list order, on each product's own page.
    for product in FirebaseProduct.all {
        let tabs = FirebaseTabs.descriptors(for: product, listed: listed, hidden: [], temporary: nil)
        check(tabs.map(\.key) == ["work42-dev", "work42-prod", "other-app"], "\(product.id): one tab per project in list order: \(tabs.map(\.key))")
        check(tabs.map(\.title) == ["Work42 Development", "Work42 Production", "Other App"], "\(product.id): tabs are titled with the display name")
        check(tabs.map(\.url.absoluteString) == listed.map { base + $0.projectId + "/" + product.consolePath }, "\(product.id): tabs open on this product's page: \(tabs.map(\.url.absoluteString))")
        check(tabs.allSatisfy { !$0.isTemporary }, "\(product.id): listed tabs aren't temporary")
    }
    check(FirebaseTabs.descriptors(for: .auth, listed: [], hidden: [], temporary: nil).isEmpty, "no projects → no tabs")

    // Hidden projects drop out of this widget only; the rest keep their order.
    let hiddenTabs = FirebaseTabs.descriptors(for: .firestore, listed: listed, hidden: ["work42-prod"], temporary: nil)
    check(hiddenTabs.map(\.key) == ["work42-dev", "other-app"], "hidden project's tab is omitted: \(hiddenTabs.map(\.key))")
    check(FirebaseTabs.descriptors(for: .firestore, listed: listed, hidden: Set(listed.map(\.projectId)), temporary: nil).isEmpty, "everything hidden → no tabs")
    check(FirebaseTabs.descriptors(for: .firestore, listed: listed, hidden: ["not-listed"], temporary: nil).count == 3, "hiding an unknown project changes nothing")

    // A temporary link tab comes last, is marked, and never appears when its project is listed.
    let temp = FirebaseTemporaryTab(projectId: "stranger", url: URL(string: "https://console.firebase.google.com/project/stranger/authentication/providers")!)
    let withTemp = FirebaseTabs.descriptors(for: .auth, listed: listed, hidden: [], temporary: temp)
    check(withTemp.last == FirebaseTabDescriptor(key: "temp:stranger", title: "stranger (link)", url: temp.url, isTemporary: true) && withTemp.count == 4, "temporary tab is last and opens its exact URL: \(withTemp.last as Any)")
    check(FirebaseTabs.descriptors(for: .auth, listed: [], hidden: [], temporary: temp).map(\.key) == ["temp:stranger"], "a temporary tab shows even with an empty list")
    let nowListed = FirebaseTabs.descriptors(for: .auth, listed: listed + [entry("stranger")], hidden: [], temporary: temp)
    check(nowListed.count == 4 && nowListed.allSatisfy { !$0.isTemporary }, "once its project is listed the temporary tab is dropped in favour of the real one")
    check(FirebaseTabs.temporaryKey("x") == "temp:x" && "temp:x".hasPrefix(FirebaseTabs.temporaryPrefix), "temporary keys are recognisable")

    // Odd IDs stay inside the Console URL; tabs with an unusable ID are skipped, not crashed on.
    let odd = FirebaseTabs.descriptors(for: .auth, listed: [entry("a/b", "Slash")], hidden: [], temporary: nil)
    check(odd.first?.url.host == "console.firebase.google.com" && odd.first?.url.absoluteString.contains("a%2Fb") == true, "a project ID with a slash is encoded: \(odd.first?.url.absoluteString ?? "nil")")

    // Hidden tabs come back whenever the list of IDs changes; not otherwise.
    check(FirebaseTabs.hiddenAfterListChange(hidden: ["a"], previousIds: ["a", "b"], currentIds: ["a", "b"]) == ["a"], "unchanged list keeps hidden tabs hidden")
    check(FirebaseTabs.hiddenAfterListChange(hidden: ["a"], previousIds: ["a", "b"], currentIds: ["a", "b", "c"]).isEmpty, "adding a project resets hidden tabs")
    check(FirebaseTabs.hiddenAfterListChange(hidden: ["a"], previousIds: ["a", "b"], currentIds: ["b"]).isEmpty, "removing a project resets hidden tabs")
    check(FirebaseTabs.hiddenAfterListChange(hidden: ["a"], previousIds: ["a", "b"], currentIds: ["b", "a"]).isEmpty, "reordering resets hidden tabs")
    check(FirebaseTabs.hiddenAfterListChange(hidden: [], previousIds: [], currentIds: []).isEmpty, "nothing to reset")

    // Empty-widget messages.
    check(FirebaseTabs.emptyMessage(listedCount: 0).hasPrefix("No Firebase projects yet.") && FirebaseTabs.emptyMessage(listedCount: 0).contains("Projects"), "empty list message points at the Projects button")
    check(FirebaseTabs.emptyMessage(listedCount: 2).hasPrefix("All projects are hidden in this widget."), "all-hidden message")
}

// MARK: - Console links

func testLinks() {
    func matches(_ product: FirebaseProduct, _ text: String) -> Bool {
        let regex = try! NSRegularExpression(pattern: product.linkPattern)
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    let host = "https://console.firebase.google.com"

    // Each product claims exactly its own pages, in every URL shape the Console uses.
    let samples: [(FirebaseProduct, [String])] = [
        (.auth, ["\(host)/project/my-app/authentication", "\(host)/project/my-app/authentication/users", "\(host)/project/my-app/authentication/providers?hl=en",
                 "\(host)/u/0/project/my-app/authentication/users", "\(host)/u/12/project/my-app/authentication#tab", "\(host)/project/my-app/authentication?x=1"]),
        (.analytics, ["\(host)/project/my-app/analytics", "\(host)/project/my-app/analytics/overview", "\(host)/u/1/project/my-app/analytics/app/android:com.x/overview"]),
        (.firestore, ["\(host)/project/my-app/firestore", "\(host)/project/my-app/firestore/databases/-default-/data", "\(host)/u/0/project/my-app/firestore/databases/-default-/indexes"]),
        (.crashlytics, ["\(host)/project/my-app/crashlytics", "\(host)/project/my-app/crashlytics/app/android:com.x/issues", "\(host)/u/0/project/my-app/crashlytics?x=1"]),
    ]
    for (owner, urls) in samples {
        for text in urls {
            for product in FirebaseProduct.all {
                check(matches(product, text) == (product == owner), "\(product.id) \(product == owner ? "claims" : "ignores") \(text)")
            }
        }
    }
    for product in FirebaseProduct.all {
        for text in ["\(host)/project/my-app/\(product.linkSegment)x", "\(host)/project/my-app/\(product.linkSegment)s/users",
                     "\(host)/project/my-app/storage", "\(host)/project/my-app/hosting", "\(host)/project/my-app/overview", "\(host)/project/my-app", "\(host)/",
                     "http://console.firebase.google.com/project/my-app/\(product.linkSegment)",
                     "https://console.firebase.google.com.evil.com/project/my-app/\(product.linkSegment)",
                     "https://evil.com/console.firebase.google.com/project/my-app/\(product.linkSegment)",
                     "https://firebase.google.com/project/my-app/\(product.linkSegment)", "https://console.firebase.google.com/project//\(product.linkSegment)",
                     "https://console.firebase.google.com/u/x/project/my-app/\(product.linkSegment)"] {
            check(!matches(product, text), "\(product.id) ignores \(text)")
        }
    }

    // Parsing: project ID (percent-decoded) and the product segment; anything else is nil.
    func parsed(_ text: String) -> String {
        guard let url = URL(string: text), let r = FirebaseProduct.parse(url) else { return "nil" }
        return "\(r.projectId)|\(r.segment)"
    }
    check(parsed("\(host)/project/my-app/authentication/users") == "my-app|authentication", "parse: plain link")
    check(parsed("\(host)/u/0/project/my-app/firestore/databases/-default-/data") == "my-app|firestore", "parse: account index")
    check(parsed("\(host)/project/dom.com%3Aproj/crashlytics?x=1#y") == "dom.com:proj|crashlytics", "parse: percent-encoded project ID is decoded")
    check(parsed("\(host)/project/my-app") == "nil" && parsed("\(host)/project/my-app/") == "nil", "parse: no product segment")
    check(parsed("https://example.com/project/my-app/authentication") == "nil" && parsed("http://console.firebase.google.com/project/my-app/authentication") == "nil", "parse: other host or scheme")
    check(parsed("\(host)/project//authentication") == "nil", "parse: empty project ID")
    check(parsed("HTTPS://CONSOLE.FIREBASE.GOOGLE.COM/project/my-app/authentication") == "my-app|authentication", "parse: scheme and host are case-insensitive")
    // Every URL a product page is built from parses back to the same project and a segment the product owns.
    for product in FirebaseProduct.all {
        for id in ["my-app", "dom.com:proj", "a/b", "ünï"] {
            let url = product.consoleURL(projectId: id)!
            let back = FirebaseProduct.parse(url)
            check(back?.projectId == id && back?.segment == product.linkSegment && matches(product, url.absoluteString), "\(product.id): consoleURL round-trips through parse and its own pattern for \(id)")
        }
    }

    // Same page: same project and product; subpages and queries count, other projects and products don't.
    func same(_ a: String, _ b: String) -> Bool { FirebaseProduct.isSamePage(URL(string: a)!, URL(string: b)!) }
    check(same("\(host)/project/my-app/authentication/providers", "\(host)/project/my-app/authentication/users"), "same page: other subpage of the same product")
    check(same("\(host)/u/0/project/my-app/authentication", "\(host)/project/my-app/authentication/users?x=1"), "same page: account index and query don't matter")
    check(!same("\(host)/project/other/authentication", "\(host)/project/my-app/authentication"), "different project is not the same page")
    check(!same("\(host)/project/my-app/firestore", "\(host)/project/my-app/authentication"), "different product is not the same page")
    check(!same("https://example.com/", "\(host)/project/my-app/authentication") && !same("\(host)/project/my-app/authentication", "https://example.com/"), "non-Console URLs are never the same page")

    // What a widget does with a clicked link.
    let listed = [entry("my-app", "My App"), entry("dom.com:proj", "Dotted")]
    func action(_ product: FirebaseProduct, _ text: String, listed: [FirebaseProjectEntry] = listed) -> FirebaseLinkAction {
        FirebaseTabs.linkAction(for: URL(string: text)!, product: product, listed: listed)
    }
    let deep = URL(string: "\(host)/project/my-app/authentication/providers")!
    check(action(.auth, deep.absoluteString) == .selectListed(projectId: "my-app", url: deep), "listed project → select its tab with the exact URL")
    let dotted = URL(string: "\(host)/project/dom.com%3Aproj/crashlytics")!
    check(action(.crashlytics, dotted.absoluteString) == .selectListed(projectId: "dom.com:proj", url: dotted), "encoded listed project ID matches the list")
    let stranger = URL(string: "\(host)/project/stranger/firestore/databases/-default-/data")!
    check(action(.firestore, stranger.absoluteString) == .openTemporary(FirebaseTemporaryTab(projectId: "stranger", url: stranger)), "unlisted project → temporary tab with the exact URL")
    check(action(.firestore, stranger.absoluteString, listed: []) == .openTemporary(FirebaseTemporaryTab(projectId: "stranger", url: stranger)), "an empty list gives a temporary tab too")
    check(action(.analytics, deep.absoluteString) == .ignore, "another product's link is ignored")
    check(action(.auth, "\(host)/project/my-app/storage") == .ignore && action(.auth, "https://example.com/") == .ignore, "other pages and hosts are ignored")

    // A freshly opened link overrides only its own tab's URL.
    let withOverride = FirebaseTabs.descriptors(for: .auth, listed: listed, hidden: [], temporary: nil, overrides: ["my-app": deep])
    check(withOverride.map(\.url) == [deep, FirebaseProduct.auth.consoleURL(projectId: "dom.com:proj")!], "override replaces one tab's URL only")
    check(FirebaseTabs.descriptors(for: .auth, listed: listed, hidden: ["my-app"], temporary: nil, overrides: ["my-app": deep]).map(\.key) == ["dom.com:proj"], "a hidden project stays hidden despite an override")
    let tempA = FirebaseTemporaryTab(projectId: "stranger", url: stranger)
    let tempB = FirebaseTemporaryTab(projectId: "other-stranger", url: URL(string: "\(host)/project/other-stranger/firestore")!)
    check(FirebaseTabs.descriptors(for: .firestore, listed: listed, hidden: [], temporary: tempB).last?.key == "temp:other-stranger" && tempA != tempB, "a new temporary tab replaces the previous one")
}

// MARK: - The read snippet in the skills

func testSkillSnippets() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var files = ["skills/firebase-setup", "skills/using-firebase"] + FirebaseProduct.all.flatMap { ["skills/firebase-\($0.id)", "widgets/\($0.widgetId)"] }
    files = files.map { $0 + "/SKILL.md" }
    func block(_ text: String) -> String? {
        captures(#"```sh\n(cfg=.*?)\n```"#.replacingOccurrences(of: ".*?", with: "[\\s\\S]*?"), in: text).first
    }
    let reference = block((try? String(contentsOf: root.appendingPathComponent("skills/using-firebase/SKILL.md"), encoding: .utf8)) ?? "")
    check(reference?.contains("python3 -") == true, "the index skill carries the read snippet")
    for file in files {
        let text = (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)) ?? ""
        check(block(text) == reference, "\(file): carries the same read snippet as the index skill")
    }
    guard let snippet = reference else { return }

    func run(_ content: String?) -> (stdout: String, stderr: String) {
        let home = makeTempDirectory(); defer { try? FileManager.default.removeItem(at: home) }
        if let content {
            try! FileManager.default.createDirectory(at: home.appendingPathComponent(".work42/firebase"), withIntermediateDirectories: true)
            try! content.write(to: home.appendingPathComponent(".work42/firebase/config.json"), atomically: true, encoding: .utf8)
        }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", snippet]
        p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        try? p.run()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (o.trimmingCharacters(in: .whitespacesAndNewlines), e)
    }
    let none = "No Firebase projects listed"
    check(run("{\"version\":2,\"projects\":[{\"projectId\":\"work42-dev\",\"displayName\":\"Work42 Development\"},{\"projectId\":\" prod \",\"displayName\":\"Prod\"}]}").stdout
          == "work42-dev - Work42 Development\nprod - Prod", "snippet lists a version 2 file, one project per line, IDs trimmed")
    check(run("{\"version\":1,\"projectId\":\"old-proj\",\"displayName\":\"Old Project\"}").stdout == "old-proj - Old Project", "snippet reads a version 1 file as one project")
    check(run("{\"version\":2,\"projects\":[{\"projectId\":\"a\"}]}").stdout == "a -", "snippet copes with a missing display name")
    for (label, content) in [("an empty list", "{\"version\":2,\"projects\":[]}"), ("an unsupported version", "{\"version\":3}"),
                             ("garbage", "oops"), ("a missing file", nil)] as [(String, String?)] {
        check(run(content).stdout == none, "snippet falls back to \"\(none)\" for \(label)")
    }
    check(run("{\"version\":3}").stderr.contains("unsupported config version 3"), "and says why for an unsupported version")
    // The snippet agrees with the app's own reader on what a valid list is.
    let dir = makeTempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("config.json")
    try! FirebaseProjectConfig.save([entry("p1", "One"), entry("p2", "Two")], to: url)
    check(run(try! String(contentsOf: url, encoding: .utf8)).stdout == "p1 - One\np2 - Two", "snippet reads what the plugin itself writes")
}

@main
struct Runner {
    @MainActor
    static func main() async {
        testConfigFile()
        testSaveFailureKeepsPreviousFile()
        testConcurrentWriters()
        await testStore()
        testParser()
        await testLister()
        await testCLIResolution()
        await testPickerModel()
        testProductCatalog()
        testIcons()
        testTabs()
        testLinks()
        testWidgetLayout()
        testSyncScriptDetectsDrift()
        testSkills()
        testManifest()
        testSkillSnippets()
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
