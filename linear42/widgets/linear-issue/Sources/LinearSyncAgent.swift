// LinearSyncAgent.swift — linear42's per-session background sync agent.
//
// ONE agent per (session x widget), started by the host while the session is
// alive, whichever tab is showing. Every `poll_seconds` it:
//   1. reloads ~/.config/linear42/config.json            (config problems -> chip)
//   2. resolves linear/issue_ref -> linear/issue          (not found -> resolve_error)
//   3. mirrors the sub-issues into plan/subtasks          (the Testing gate reads it)
//   4. reads plan APPROVAL back from the Linear state     (writes plan/approved_at)
//   5. pushes the session stage to its mapped Linear state
//   6. retries the Linear approval stamp if a Work42 approval isn't stamped yet
//   7. publishes the header chips
// One `linear api` GraphQL call per poll feeds all of it. The `linear` CLI is the
// only thing that talks to Linear.
//
// WRITES go through `work42 storage set|delete` in the shell, never through
// `services.storage`: the host binds a background agent's storage to the widget
// SLUG ("linear-issue"), so it could not write the `plan/*` or `linear/*` keys the
// gates need. The CLI is session-scoped (WORK42_SESSION_ID) and, like every
// storage write, re-checks the workflow gates — which is what posts the
// "In-Progress is now available" nudge when approval arrives from Linear.
//
// There is no system-event channel for widgets (the `task42 event` CLI the
// Jira/GitHub widgets call no longer ships), so problems surface as warning chips
// in the session header and in the widget instead of events.

import Foundation
import Observation
import Work42PluginKit

extension LinearIssueWidget: Work42WidgetBackground {
    func makeBackgroundAgent() -> any WidgetBackgroundAgent {
        // Fresh instance per call — per-session isolation.
        LinearSyncAgent()
    }
}

@Observable
@MainActor
final class LinearSyncAgent: WidgetBackgroundAgent {

    /// Session-scoped header chips (@Observable-backed: only the header strip re-renders).
    var headerLabels: [WidgetHeaderLabel] = []

    private var pollTask: Task<Void, Never>?
    /// The approval timestamp we already commented on, so a retry after a failed
    /// state move doesn't post the comment twice.
    private var commentedApprovalAt: String?

    func start(services: WidgetBackgroundServices) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let seconds = await self?.cycle(services: services) ?? Linear42Config.defaultPollSeconds
                try? await Task.sleep(nanoseconds: UInt64(max(seconds, 1)) * 1_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        headerLabels = []
    }

    // MARK: - One poll cycle

    /// Returns the number of seconds to sleep before the next cycle.
    private func cycle(services: WidgetBackgroundServices) async -> Int {
        let config: Linear42Config
        switch Linear42Config.load() {
        case .failure:
            publish([WidgetHeaderLabel(text: "linear42: not configured", systemIcon: "gearshape", tint: .warning)])
            return Linear42Config.defaultPollSeconds
        case .success(let loaded):
            config = loaded
        }

        let ref: String?
        do {
            ref = string(try await services.storage.get(namespace: "linear", key: "issue_ref"))
        } catch {
            return config.pollSeconds // storage briefly unavailable — keep the last chips
        }
        guard let ref, let key = linearIssueKey(from: ref) else {
            publish([]) // unbound session
            return config.pollSeconds
        }

        switch await fetch(key: key, services: services) {
        case .ok(let issue):
            await apply(issue, config: config, services: services)
        case .notFound:
            await ensure("linear/resolve_error", .string("not_found"), services)
            publish([
                WidgetHeaderLabel(text: key, systemIcon: "list.bullet.rectangle", groupId: key),
                WidgetHeaderLabel(text: "not found", tint: .failure, groupId: key),
            ])
        case .cliMissing:
            await ensure("linear/cli_error", .string("missing"), services)
            publish([WidgetHeaderLabel(text: "linear CLI not installed", systemIcon: "exclamationmark.triangle", tint: .warning)])
        case .cliAuth:
            await ensure("linear/cli_error", .string("auth"), services)
            publish([WidgetHeaderLabel(text: "linear: sign in", systemIcon: "exclamationmark.triangle", tint: .warning)])
        case .transient:
            break // rate limit / network / undecodable output — leave storage and chips as they were
        }
        return config.pollSeconds
    }

    private func apply(
        _ issue: LinearIssuePayload,
        config: Linear42Config,
        services: WidgetBackgroundServices
    ) async {
        // A good read clears any earlier CLI / resolution problem.
        await ensureAbsent("linear/cli_error", services)
        await ensureAbsent("linear/resolve_error", services)

        // Resolved issue + the sub-issue mirror the Testing gate reads.
        await ensure("linear/issue", .object([
            "key": .string(issue.key), "id": .string(issue.id), "url": .string(issue.url),
            "team": .string(issue.teamKey), "title": .string(issue.title),
        ]), services)
        await ensure("plan/subtasks", .array(issue.children.map { child in
            .object([
                "id": .string(child.key), "title": .string(child.title),
                "description": .string(child.description), "done": .bool(child.done),
                "state": .string(child.stateName),
            ])
        }), services)

        // Approval read-back (writing plan/approved_at last: the write re-checks the
        // gates and posts the transition nudge once subtasks + approval both exist).
        let stage = stageName(await read("session", "stage", services))
        var approvedAt = string(await read("plan", "approved_at", services))
        var hasSpecDoc = false
        if case .object? = await read("linear", "spec_doc", services) { hasSpecDoc = true }
        if shouldApproveFromLinear(
            stage: stage,
            approvedAtPresent: approvedAt != nil,
            lastStateType: string(await read("linear", "last_state_type", services)),
            currentStateType: issue.stateType,
            hasSpecDoc: hasSpecDoc,
            hasSubIssues: !issue.children.isEmpty
        ) {
            let now = ISO8601DateFormatter().string(from: Date())
            await ensure("plan/approved_by", .string("linear"), services)
            await ensure("linear/approval_stamped", .bool(true), services)
            await ensure("plan/approved_at", .string(now), services)
            approvedAt = now
        }
        await ensure("linear/last_state_type", .string(issue.stateType), services)

        var currentState = issue.stateName
        var warnings: [WidgetHeaderLabel] = []
        await pushStage(stage, issue: issue, config: config, services: services,
                        currentState: &currentState, warnings: &warnings)
        await retryApprovalStamp(approvedAt: approvedAt, issue: issue, config: config, services: services,
                                 currentState: &currentState, warnings: &warnings)

        publish(chips(for: issue, stateName: currentState) + warnings)
    }

    // MARK: - Stage -> Linear state

    private func pushStage(
        _ stage: String?,
        issue: LinearIssuePayload,
        config: Linear42Config,
        services: WidgetBackgroundServices,
        currentState: inout String,
        warnings: inout [WidgetHeaderLabel]
    ) async {
        guard let stage else { return }
        let pushed = string(await read("linear", "pushed_stage", services))
        guard stage != pushed else { return }
        // First sight of a bound issue while Planning: adopt the stage without
        // pushing, so binding an issue that is already in progress never demotes it.
        if pushed == nil && stage == "Planning" {
            await ensure("linear/pushed_stage", .string(stage), services)
            return
        }
        switch resolveStageState(stage: stage, teamKey: issue.teamKey, states: issue.states, stageStates: config.stageStates) {
        case .skip:
            await ensure("linear/pushed_stage", .string(stage), services)
        case .missingOverride(let name):
            // No pushed_stage write: retried every poll, and the chip stays until config is fixed.
            warnings.append(WidgetHeaderLabel(text: "no state \"\(name)\"", systemIcon: "exclamationmark.triangle", tint: .warning, groupId: issue.key))
        case .move(let name):
            if name == currentState {
                await ensure("linear/pushed_stage", .string(stage), services)
            } else if await updateState(issue.key, to: name, services) {
                currentState = name
                await ensure("linear/pushed_stage", .string(stage), services)
            }
        }
    }

    // MARK: - Approval stamp (Work42 approval -> Linear)

    /// A plan approved in Work42 must show in Linear: a comment linking the spec and the
    /// issue in its In-Progress-mapped state. The Approve action does this itself; this
    /// retries it when that failed, or when approval was written directly to storage.
    private func retryApprovalStamp(
        approvedAt: String?,
        issue: LinearIssuePayload,
        config: Linear42Config,
        services: WidgetBackgroundServices,
        currentState: inout String,
        warnings: inout [WidgetHeaderLabel]
    ) async {
        guard let approvedAt else { return }
        if case .bool(true)? = await read("linear", "approval_stamped", services) { return }

        if commentedApprovalAt != approvedAt {
            let approver = string(await read("plan", "approved_by", services)) ?? "Work42"
            var body = "Plan approved in Work42 by \(approver)"
            if case .object(let doc)? = await read("linear", "spec_doc", services), case .string(let url)? = doc["url"] {
                body += " — spec: \(url)"
            }
            guard await run("linear issue comment add \(shellQuote(issue.key)) --body \(shellQuote(body))", services) else { return }
            commentedApprovalAt = approvedAt
        }
        switch resolveStageState(stage: "In-Progress", teamKey: issue.teamKey, states: issue.states, stageStates: config.stageStates) {
        case .skip:
            break
        case .missingOverride(let name):
            warnings.append(WidgetHeaderLabel(text: "no state \"\(name)\"", systemIcon: "exclamationmark.triangle", tint: .warning, groupId: issue.key))
            return
        case .move(let name):
            if name != currentState {
                guard await updateState(issue.key, to: name, services) else { return }
                currentState = name
            }
        }
        await ensure("linear/approval_stamped", .bool(true), services)
    }

    // MARK: - Chips

    private func chips(for issue: LinearIssuePayload, stateName: String) -> [WidgetHeaderLabel] {
        let url = URL(string: issue.url)
        var labels = [
            WidgetHeaderLabel(text: issue.key, systemIcon: "list.bullet.rectangle", url: url, groupId: issue.key),
            WidgetHeaderLabel(text: stateName, tint: tint(forStateType: issue.states.first { $0.name == stateName }?.type ?? issue.stateType), url: url, groupId: issue.key),
        ]
        if !issue.children.isEmpty {
            let done = issue.children.filter(\.done).count
            labels.append(WidgetHeaderLabel(
                text: "\(done)/\(issue.children.count) sub-issues",
                systemIcon: "checklist",
                tint: done == issue.children.count ? .success : .neutral,
                url: url,
                groupId: issue.key
            ))
        }
        return labels
    }

    private func tint(forStateType type: String) -> WidgetHeaderLabelTint {
        switch type {
        case "completed": return .success
        case "started": return .warning
        case "canceled": return .failure
        default: return .neutral
        }
    }

    private func publish(_ labels: [WidgetHeaderLabel]) {
        if labels != headerLabels { headerLabels = labels }
    }

    // MARK: - Linear CLI

    private enum FetchOutcome {
        case ok(LinearIssuePayload)
        case notFound, cliMissing, cliAuth, transient
    }

    private func fetch(key: String, services: WidgetBackgroundServices) async -> FetchOutcome {
        let variables = json(.object(["id": .string(key)]))
        let command = "linear api \(shellQuote(linearIssueQuery)) --variables-json \(shellQuote(variables))"
        guard let result = try? await services.shell.run(command: linearCLIPathPrefix + command) else { return .transient }
        switch result.exitCode {
        case 0:
            guard let data = result.stdout.data(using: .utf8), let payload = parseIssuePayload(data) else { return .transient }
            return .ok(payload)
        case 127: return .cliMissing
        case 4: return .cliAuth
        case 3: return .notFound
        default: return .transient // 5 = rate limited / unavailable, or anything else: retry next poll
        }
    }

    private func updateState(_ key: String, to state: String, _ services: WidgetBackgroundServices) async -> Bool {
        await run("linear issue update \(shellQuote(key)) --state \(shellQuote(state))", services)
    }

    private func run(_ command: String, _ services: WidgetBackgroundServices) async -> Bool {
        guard let result = try? await services.shell.run(command: linearCLIPathPrefix + command) else { return false }
        return result.exitCode == 0
    }

    // MARK: - Storage helpers

    private func read(_ namespace: String, _ key: String, _ services: WidgetBackgroundServices) async -> WidgetJSONValue? {
        (try? await services.storage.get(namespace: namespace, key: key)) ?? nil
    }

    private func string(_ value: WidgetJSONValue?) -> String? {
        if case .string(let s)? = value, !s.isEmpty { return s }
        return nil
    }

    private func stageName(_ value: WidgetJSONValue?) -> String? {
        if case .object(let o)? = value, case .string(let name)? = o["name"] { return name }
        return nil
    }

    private func json(_ value: WidgetJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "null" }
        return text
    }

    /// Writes `namespace/key` only when it differs from what is stored, so an
    /// unchanged poll writes nothing (no gate re-check, no `updated_at` churn).
    private func ensure(_ address: String, _ value: WidgetJSONValue, _ services: WidgetBackgroundServices) async {
        let parts = address.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        if await read(parts[0], parts[1], services) == value { return }
        _ = await run("work42 storage set \(shellQuote(address)) \(shellQuote(json(value)))", services)
    }

    private func ensureAbsent(_ address: String, _ services: WidgetBackgroundServices) async {
        let parts = address.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, await read(parts[0], parts[1], services) != nil else { return }
        _ = await run("work42 storage delete \(shellQuote(address))", services)
    }
}
