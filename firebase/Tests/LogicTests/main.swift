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
    check(shared == ["FirebaseConsoleWidget.swift", "FirebaseProduct.swift", "FirebaseProjectConfig.swift", "FirebaseProjectPicker.swift"], "shared sources: \(shared)")
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
    check(fields["name"] == "firebase" && fields["version"] == "0.1.0", "name and version")
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
        testProductCatalog()
        testWidgetLayout()
        testSyncScriptDetectsDrift()
        testSkills()
        testManifest()
        print("\(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
