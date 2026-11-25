// Plugin.swift — linear42's compiled onCreate session hook.
//
// Creates the linked To-Do (`work42://task/<sessionId>`) for a new
// `linear-task` session — the same post-worktree side effect task42's hook
// has. A plugin hooks dylib links only Work42PluginKit (see
// PluginHookInstaller's build args), so it cannot reach Flow42Core's
// PlannedDayStore directly; it shells out to `todo42 todos add` instead.
//
// `linear/issue_ref` is NOT written here — it is seeded declaratively from
// session-types/linear-task.json's `issue` arg (SessionMint's generic
// arg -> storage path) before onCreate ever runs.
//
// `todo42 todos add` does not dedupe by url — safe because onCreate only
// fires on a genuinely new session insert (SessionMint.finishMint's
// `guard inserted else { return }`), never on a re-mint.

import Foundation
import Work42PluginKit

final class Linear42Hooks: Work42SessionHooks {
    func onCreate(_ context: SessionCreateContext) async throws {
        let url = "work42://task/\(context.sessionId)"
        let command = "todo42 todos add --title \(shellQuote(context.name)) --url \(shellQuote(url))"
        let result = try await context.shell.run(command: command)
        // 127: todo42 is not installed. The To-Do is a convenience, so the session is still valid without it.
        if result.exitCode == 127 { return }
        guard result.exitCode == 0 else {
            throw WidgetServiceError(
                message: "todo42 todos add failed (exit \(result.exitCode)): \(result.stderr)",
                suggestion: "check `todo42` is installed (ask the agent to run the todo42-setup skill) and \(context.worktreePath) resolves a workspace"
            )
        }
    }
}
