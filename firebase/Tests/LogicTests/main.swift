// Logic tests for FirebaseProjectConfig / FirebaseProjectStore / parser / lister / picker model.
// Plain executable (no XCTest), same shape as linear42's Tests/LogicTests. Exits non-zero on any failure.

import Foundation

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

func sel(_ id: String, _ name: String? = nil) -> FirebaseProjectSelection {
    FirebaseProjectSelection(projectId: id, displayName: name ?? id)
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

    check((try? FirebaseProjectConfig.load(from: url)) == .some(nil), "absent file loads as nil, not an error")

    try! FirebaseProjectConfig.save(sel("work42-dev", "Work42 Development"), to: url)
    check(FileManager.default.fileExists(atPath: url.path), "save creates intermediate directories")
    check((try? FirebaseProjectConfig.load(from: url)) == sel("work42-dev", "Work42 Development"), "round trip")
    let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    check(Set(json.keys) == ["version", "projectId", "displayName"], "file holds exactly version/projectId/displayName: \(json.keys)")
    check(json["version"] as? Int == 1, "version is 1")
    let leftovers = try! FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
    check(leftovers == ["config.json"], "no temp files left behind: \(leftovers)")

    // Blank display name falls back to the ID; project ID is trimmed.
    try! FirebaseProjectConfig.save(FirebaseProjectSelection(projectId: " p1 ", displayName: "  "), to: url)
    check((try? FirebaseProjectConfig.load(from: url)) == sel("p1"), "blank displayName falls back to projectId, id trimmed")

    // Corrupt / invalid / unsupported files are errors, and reading never modifies them.
    func write(_ text: String) { try! text.write(to: url, atomically: false, encoding: .utf8) }
    write("{not json")
    check(configError { try FirebaseProjectConfig.load(from: url) } == .corrupt("not a valid selection"), "garbage is corrupt")
    write("{\"version\":1,\"projectId\":\"  \",\"displayName\":\"x\"}")
    check(configError { try FirebaseProjectConfig.load(from: url) } == .corrupt("projectId is empty"), "empty project ID is corrupt")
    write("{\"version\":1,\"displayName\":\"x\"}")
    check(configError { try FirebaseProjectConfig.load(from: url) } != nil, "missing projectId is an error")
    write("{\"version\":2,\"projectId\":\"p\",\"displayName\":\"p\"}")
    check(configError { try FirebaseProjectConfig.load(from: url) } == .unsupportedVersion(2), "newer version is unsupported")
    write("{\"version\":3,\"somethingNew\":true}")
    check(configError { try FirebaseProjectConfig.load(from: url) } == .unsupportedVersion(3), "newer schema without our fields reports its version")
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
    try! FirebaseProjectConfig.save(sel("keep-me", "Keep Me"), to: url)
    let original = try! Data(contentsOf: url)

    // Parent directory is read-only: the temp file can't be created.
    try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    if case .writeFailed? = configError({ try FirebaseProjectConfig.save(sel("other"), to: url); return nil }) {} else {
        check(false, "save into a read-only directory throws writeFailed")
    }
    check((try! Data(contentsOf: url)) == original, "failed save leaves the previous file byte-for-byte intact")
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
    check(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []) == ["config.json"], "failed save leaves no temp file")

    // A path component that is a regular file can't become a directory.
    let blocked = dir.appendingPathComponent("config.json/nested/config.json")
    if case .writeFailed? = configError({ try FirebaseProjectConfig.save(sel("x"), to: blocked); return nil }) {} else {
        check(false, "save under a regular file throws writeFailed")
    }
    check((try! Data(contentsOf: url)) == original, "still intact after blocked-path failure")

    // Refuses to persist an empty project.
    check(configError({ try FirebaseProjectConfig.save(FirebaseProjectSelection(projectId: " ", displayName: "n"), to: url); return nil }) != nil, "empty projectId refused")
    check((try! Data(contentsOf: url)) == original, "refused save changed nothing")
}

func testConcurrentWriters() {
    let dir = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("config.json")
    try! FirebaseProjectConfig.save(sel("seed"), to: url)

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
                do { try FirebaseProjectConfig.save(sel("writer-\(w)-\(r)", "Writer \(w)"), to: url) } catch { lock.lock(); writeFailures += 1; lock.unlock() }
            }
            lock.lock(); finished += 1; lock.unlock()
            group.leave()
        }
    }
    group.enter()
    DispatchQueue.global().async {
        while true {
            lock.lock(); let done = finished == writers; lock.unlock()
            // Every read, mid-storm, must see a complete valid selection: never torn, never missing.
            do { if try FirebaseProjectConfig.load(from: url) == nil { lock.lock(); readFailures += 1; lock.unlock() } }
            catch { lock.lock(); readFailures += 1; lock.unlock() }
            if done { break }
        }
        group.leave()
    }
    group.wait()
    check(writeFailures == 0, "no writer failed under contention (\(writeFailures))")
    check(readFailures == 0, "readers never saw a torn or missing file (\(readFailures))")
    let final = try? FirebaseProjectConfig.load(from: url)
    check(final?.projectId.hasPrefix("writer-") == true && final?.projectId.hasSuffix("-\(rounds - 1)") == true,
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
    check(a.state == .none && b.state == .none, "absent file → .none")
    check(a.isRunning, "started store is running")

    try! a.select(sel("proj-1", "Project One"))
    check(a.state == .selected(sel("proj-1", "Project One")), "select adopts immediately in the chooser")
    await eventually("other store sees the new selection through the file within 2s") { b.state == .selected(sel("proj-1", "Project One")) }

    // Atomic replacement by an outside process, even with identical size.
    try! FirebaseProjectConfig.save(sel("proj-2", "Project Two"), to: url)
    await eventually("both stores converge on an external atomic replacement") { a.state.projectId == "proj-2" && b.state.projectId == "proj-2" }

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

    // An invalid external edit becomes .invalid and is left alone; picking repairs it.
    try! "oops".write(to: url, atomically: true, encoding: .utf8)
    await eventually("corrupt edit → .invalid") { if case .invalid = a.state { return true } else { return false } }
    check((try! String(contentsOf: url, encoding: .utf8)) == "oops", "invalid file is not overwritten by reading")
    try! b.select(sel("proj-3"))
    await eventually("explicit selection repairs it for everyone") { a.state.projectId == "proj-3" }

    // Removal returns to .none.
    try! FileManager.default.removeItem(at: url)
    await eventually("deleted file → .none") { a.state == .none }

    // stop() ends observation.
    a.stop()
    check(!a.isRunning, "stopped store is not running")
    try! FirebaseProjectConfig.save(sel("after-stop"), to: url)
    try? await Task.sleep(nanoseconds: 300_000_000)
    check(a.state == .none, "a stopped store no longer follows the file")
    a.start()
    check(a.state.projectId == "after-stop", "start() re-reads on activation")
    a.stop(); b.stop()

    // select() failing leaves state alone.
    let blocker = dir.appendingPathComponent("blocker")
    try! "file".write(to: blocker, atomically: true, encoding: .utf8)
    let c = FirebaseProjectStore(url: blocker.appendingPathComponent("config.json"), interval: 0.05)
    var threw = false
    do { try c.select(sel("x")) } catch { threw = true }
    check(threw && c.state == .none, "failed select throws and leaves state unchanged")
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
    check(shell.calls == ["firebase projects:list --json --non-interactive"], "exact CLI command: \(shell.calls)")

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
    let store = FirebaseProjectStore(url: url, interval: 0.05)
    let alpha = FirebaseProject(projectId: "alpha-1", displayName: "Alpha App")
    let beta = FirebaseProject(projectId: "beta-2", displayName: "Beta Service")
    let list = envelope([("alpha-1", "Alpha App"), ("beta-2", "Beta Service")])

    // Loading → loaded; search by name and by ID; refresh.
    let shell = FakeShell(ok(list))
    let model = FirebaseProjectPickerModel(run: shell.runner, store: store)
    check(model.phase == .idle, "starts idle")
    await model.refresh()
    check(model.phase == .loaded([alpha, beta]), "loaded: \(model.phase)")
    model.query = "BETA"; check(model.filtered == [beta], "search by name, case-insensitive")
    model.query = "alpha-1"; check(model.filtered == [alpha], "search by ID")
    model.query = "zzz"; check(model.filtered.isEmpty, "no match")
    model.query = ""; check(model.filtered == [alpha, beta], "cleared query shows all")
    await model.refresh()
    check(shell.calls.count == 2, "refresh re-runs the CLI")

    // Confirm writes only the listed project; cancelling writes nothing.
    check(!FileManager.default.fileExists(atPath: url.path), "nothing written before confirming")
    check(!model.confirm(FirebaseProject(projectId: "ghost", displayName: "Ghost")), "unlisted project refused")
    check(model.saveError != nil && !FileManager.default.fileExists(atPath: url.path), "refusal writes nothing")
    check(model.confirm(beta), "listed project confirmed")
    check((try? FirebaseProjectConfig.load(from: url)) == sel("beta-2", "Beta Service"), "confirmed project persisted")
    check(store.state == .selected(sel("beta-2", "Beta Service")), "store adopts it")
    check(model.isFinished && !model.confirm(alpha), "a finished picker can't write again")

    // Cancel: no write, and a late result is dropped.
    let slow = FakeShell(ok(list)); slow.delayNanos = 300_000_000
    let cancelled = FirebaseProjectPickerModel(run: slow.runner, store: store)
    let before = try! Data(contentsOf: url)
    let pending = Task { await cancelled.refresh() }
    try? await Task.sleep(nanoseconds: 50_000_000)
    check(cancelled.phase == .loading, "slow listing is loading")
    cancelled.cancel()
    await pending.value
    check(cancelled.phase == .loading, "late result after cancel doesn't change state: \(cancelled.phase)")
    check(!cancelled.confirm(alpha), "cancelled picker refuses to commit")
    check((try! Data(contentsOf: url)) == before && store.state.projectId == "beta-2", "cancel leaves the config unchanged")

    // Only one request at a time.
    let counting = FakeShell(ok(list)); counting.delayNanos = 200_000_000
    let busy = FirebaseProjectPickerModel(run: counting.runner, store: store)
    async let first: Void = busy.refresh()
    try? await Task.sleep(nanoseconds: 30_000_000)
    async let second: Void = busy.refresh()
    async let third: Void = busy.refresh()
    _ = await (first, second, third)
    check(counting.calls.count == 1, "overlapping refreshes run the CLI once (\(counting.calls.count))")
    check(busy.phase == .loaded([alpha, beta]), "and still end loaded")

    // Failure → failed → retry succeeds.
    let flaky = FakeShell(FirebaseShellResult(stdout: "", stderr: "zsh: command not found: firebase", exitCode: 127))
    let retry = FirebaseProjectPickerModel(run: flaky.runner, store: store)
    await retry.refresh()
    if case .failed(let message) = retry.phase { check(message.contains("firebase-setup"), "missing CLI points to setup: \(message)") }
    else { check(false, "failed phase expected, got \(retry.phase)") }
    check(retry.confirm(alpha) == false, "can't confirm from a failed listing")
    flaky.result = ok(list)
    await retry.refresh()
    check(retry.phase == .loaded([alpha, beta]), "retry after failure loads")

    // Save failure keeps the previous selection and reports why.
    let blocker = dir.appendingPathComponent("blocker")
    try! "file".write(to: blocker, atomically: true, encoding: .utf8)
    let brokenStore = FirebaseProjectStore(url: blocker.appendingPathComponent("config.json"), interval: 0.05)
    try? FirebaseProjectConfig.save(sel("existing"), to: url)
    let saving = FirebaseProjectPickerModel(run: FakeShell(ok(list)).runner, store: brokenStore)
    await saving.refresh()
    check(!saving.confirm(alpha), "failed save returns false")
    check(saving.saveError?.contains("Couldn't save") == true, "save error surfaced: \(String(describing: saving.saveError))")
    check(!saving.isFinished, "picker stays open after a failed save so the user can retry")
    check(brokenStore.state == .none && (try? FirebaseProjectConfig.load(from: url))?.projectId == "existing", "previous selection retained")

    // Empty project list is a loaded-but-empty state, not an error.
    let empty = FirebaseProjectPickerModel(run: FakeShell(ok(envelope([]))).runner, store: store)
    await empty.refresh()
    check(empty.phase == .loaded([]) && empty.filtered.isEmpty, "empty list")
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
        await testPickerModel()
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
