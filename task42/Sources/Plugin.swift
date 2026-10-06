// Plugin.swift — task42's compiled onCreate session hook
// (task42-plugin-conversion, c4).
//
// Reproduces only the POST-worktree side effect of the built-in task
// seeder this plugin replaces (work42/Sources/Work42App/Sessions/
// SessionSeeders.swift's "task" seeder): create the linked To-Do
// (`work42://task/<sessionId>`). A plugin hooks dylib links only
// Work42PluginKit (see PluginHookInstaller's build args), so it cannot
// reach Flow42Core's PlannedDayStore/TodoSessionLink directly — this
// shells out to `work42 todos add` instead, the CLI-mediated equivalent.
//
// `plan/kind` and `jira/url` are NOT written here — they're seeded
// declaratively from session-types/task.json's `args` (SessionMint's
// generic arg->storage path, task42-plugin-conversion s1) before onCreate
// ever runs.
//
// `work42 todos add` does not dedupe by url the way
// `TodoSessionLink.ensureTodo` does — safe here because onCreate only
// fires on a genuinely new session insert (SessionMint.finishMint's
// `guard inserted else { return }`), never on a re-mint.

import Foundation
import Work42PluginKit

final class Task42Hooks: Work42SessionHooks {
    func onCreate(_ context: SessionCreateContext) async throws {
        let url = "work42://task/\(context.sessionId)"
        let command = "work42 todos add --title \(shellQuote(context.name)) --url \(shellQuote(url))"
        let result = try await context.shell.run(command: command)
        guard result.exitCode == 0 else {
            throw WidgetServiceError(
                message: "work42 todos add failed (exit \(result.exitCode)): \(result.stderr)",
                suggestion: "check `work42` is on PATH and \(context.worktreePath) resolves a workspace"
            )
        }
    }
}

/// POSIX single-quote shell escaping for a value interpolated into a
/// `/bin/sh -c` command line (`WidgetCommandRunner`, the host's shell
/// backend) — wraps in single quotes, escaping an embedded `'` as `'\''`.
/// A session's display name may contain spaces/quotes.
private nonisolated func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Plugin entry-point ABI

// The two @_cdecl symbols the app's dlopen/dlsym loader expects (mirrors
// every widget's work42_widget_main/work42_widget_sdk_version pair).
// `nonisolated(unsafe)` local is required because MainActor.assumeIsolated
// cannot return an UnsafeMutableRawPointer directly (not Sendable).

@_cdecl("work42_plugin_sdk_version")
public func work42_plugin_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_plugin_main")
public func work42_plugin_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = PluginEntryPoint.register(Task42Hooks())
    }
    return result
}
