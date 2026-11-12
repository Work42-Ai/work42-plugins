// Widget.swift — task42's Spec widget (task42-plugin-conversion, c5).
//
// Renders `plan/spec` (this session's technical plan) as a themed,
// comment- and artifact-integrated markdown document via Work42UI's
// Work42MarkdownDocument (s6), and declares the Approve Plan action as
// its own WidgetIntentSpec (v7 service-aware init) — the same seam the
// built-in spec widget's approvePlanIntentSpec used, but reading its OWN
// cached storage state instead of the app-internal PaletteController
// bridge (SessionCommandSink), which a plugin widget has no access to.
//
// STORAGE (storageNamespace "plan" — shared with the subtasks/testing-plan
// widgets and the workflow gates):
//   plan/spec         — the spec markdown. Read-only here; written by the
//                        agent via the `storage_set` tool (key `plan/spec`).
//   plan/approved_at  — ISO-8601 timestamp; written by Approve Plan.
//   plan/approved_by  — the approver's username; written by Approve Plan.
// Approval is simply the presence of plan/approved_at — there is no
// separate tracker/status to move.

import Foundation
import Observation
import SwiftUI
import Work42PluginKit

@Observable
@MainActor
final class SpecWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "spec"
    let title = "Spec"
    let icon = "doc.text"
    var storageNamespace: String? { "plan" }
    var linkIntents: [WidgetLinkIntentSpec] { [] }

    /// What a collaborator can be allowed to do here: use the widget, and approve the plan.
    var scopes: [WidgetScopeSpec] { [.use, WidgetScopeSpec(id: "approve", title: "Approve the plan")] }

    /// One button, for the owner and for reviewers, that reads and confirms differently for each of them: the owner's approval and a
    /// reviewer's sign-off are two entries under the same widget (`plan/approved`, `plan/reviewed`), each stored for the person who
    /// gave it. An agent and a member without the reviewer role get no button.
    var intents: [WidgetIntentSpec] {
        [
            WidgetIntentSpec(
                name: "approvePlan",
                title: "Approve Plan",
                icon: "checkmark.seal.fill",
                placement: [.palette, .actionArea],
                actionAreaStyle: .labeled,
                isEnabled: nil,
                isConfirmed: nil,
                onConfirmedTap: { [weak self] services in
                    await self?.revokeApproval(services: services)
                },
                performWithServices: { [weak self] services in
                    await self?.approvePlan(services: services)
                }
            )
            .forAudience(WidgetAudience([.owners, .role("reviewer")]))
            .requiring("approve")
            .perViewer(
                title: { [weak self] who in self?.buttonTitle(for: who) ?? "Approve Plan" },
                isEnabled: { [weak self] who in self?.canApprove(for: who) ?? false },
                isConfirmed: { [weak self] who in self?.hasApproved(who) ?? false }),
        ]
    }

    // MARK: - Per person

    /// People who gave the owner's approval (`plan/approved`) and the reviewer's (`plan/reviewed`), by person id.
    var approvers: Set<String> = []
    var reviewers: Set<String> = []

    /// The key `who` signs under: the owner approves, anyone else holding the reviewer role reviews.
    private func key(for who: WidgetCollaborator) -> String { who.isOwner ? "approved" : "reviewed" }

    func hasApproved(_ who: WidgetCollaborator) -> Bool {
        who.isOwner ? approvers.contains(who.id) : reviewers.contains(who.id)
    }

    func buttonTitle(for who: WidgetCollaborator) -> String {
        if isApproving { return "Approving…" }
        switch (who.isOwner, hasApproved(who)) {
        case (true, true): return "Plan approved"
        case (true, false): return "Approve Plan"
        case (false, true): return "Approved as reviewer"
        case (false, false): return "Approve as reviewer"
        }
    }

    func canApprove(for who: WidgetCollaborator) -> Bool { hasSpec && !isApproving && !hasApproved(who) }

    // MARK: - Observed state

    var spec: String?
    var isApproved = false
    var isApproving = false
    var hasSpec: Bool { spec?.isEmpty == false }

    private var services: SessionServices?

    // MARK: - Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        if let sessionId = services.sessionId, let worktreePath = services.worktreePath {
            try? ArtifactRuntime.register(sessionId: sessionId, directory: worktreePath)
        }
        Task { @MainActor [weak self] in
            await self?.load()
        }
    }

    func deactivate() {
        services = nil
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(SpecWidgetView(widget: self, services: services))
    }

    // MARK: - Storage

    func load() async {
        guard let services else { return }
        let specValue = (try? await services.storage.get(namespace: "plan", key: "spec")) ?? nil
        let newSpec: String?
        if case .string(let text)? = specValue { newSpec = text } else { newSpec = nil }
        if newSpec != spec { spec = newSpec }
        let approvedAt = (try? await services.storage.get(namespace: "plan", key: "approved_at")) ?? nil
        let newApproved = approvedAt != nil
        if newApproved != isApproved { isApproved = newApproved }
        let owners = Set(((try? await services.storage.people(key: "approved")) ?? [:]).keys)
        let others = Set(((try? await services.storage.people(key: "reviewed")) ?? [:]).keys)
        if owners != approvers { approvers = owners }
        if others != reviewers { reviewers = others }
    }

    /// Records the acting person's own approval (`services.actor` is whoever pressed the button, on this Mac or another device),
    /// and for the owner also the keys the In-Progress gate and readers of the plan use.
    private func approvePlan(services: SessionServices) async {
        let who = services.actor
        guard canApprove(for: who) else { return }
        isApproving = true
        defer { isApproving = false }
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            // Their own entry first: it is what the people-count gate reads, and only they can write it.
            try await services.storage.setPerson(key: key(for: who), value: .string(now))
            if who.isOwner {
                try await services.storage.set(key: "approved_by", value: .string(who.displayName))
                try await services.storage.set(key: "approved_at", value: .string(now))
                isApproved = true
                approvers.insert(who.id)
            } else {
                reviewers.insert(who.id)
            }
        } catch {
            // Non-fatal — the button stays actionable; the palette surfaces
            // the failure from the intent invocation itself.
        }
    }

    /// Takes back the acting person's own approval. When the owner takes theirs back, `plan/approved_at` (the gate signal) and
    /// `plan/approved_by` go too.
    private func revokeApproval(services: SessionServices) async {
        let who = services.actor
        do {
            try await services.storage.deletePerson(key: key(for: who))
            if who.isOwner {
                try await services.storage.delete(key: "approved_at")
                try await services.storage.delete(key: "approved_by")
                isApproved = false
                approvers.remove(who.id)
            } else {
                reviewers.remove(who.id)
            }
        } catch {
            // Non-fatal — the button stays confirmed; the host surfaces the failure.
        }
    }
}

// MARK: - SpecWidgetView

private struct SpecWidgetView: View {
    let widget: SpecWidget
    let services: SessionServices

    var body: some View {
        VStack(spacing: 0) {
            if !widget.approvers.isEmpty || !widget.reviewers.isEmpty {
                HStack(spacing: DT.s8) {
                    Image(systemName: "checkmark.seal").foregroundStyle(DT.textSecondary)
                    Text("Owner \(widget.approvers.count) · Reviewers \(widget.reviewers.count)")
                        .font(.system(size: DT.f11))
                        .foregroundStyle(DT.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DT.s12)
                .padding(.vertical, DT.s4)
            }
            content
        }
        .task {
            // Live refresh: agent/CLI writes to `plan/spec` and `plan/approved_at` land while this tab is
            // open. `.task` is cancelled when the view leaves the screen.
            await widget.load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                if Task.isCancelled { break }
                await widget.load()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let spec = widget.spec, !spec.isEmpty {
                Work42MarkdownDocument(
                    text: spec,
                    sessionId: services.sessionId,
                    commentKey: "plan/spec",
                    artifactsEnabled: true,
                    baseURL: services.worktreePath.map { URL(fileURLWithPath: $0) }
                )
            } else {
                VStack(alignment: .leading, spacing: DT.s8) {
                    Text("No spec yet")
                        .font(.system(size: DT.f13, weight: .semibold))
                    Text("Draft one with the `storage_set` tool (key `plan/spec`), then approve it here.")
                        .font(.system(size: DT.f12))
                        .foregroundStyle(DT.textSecondary)
                }
                .padding(DT.s16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Widget entry-point ABI

// The two @_cdecl symbols the app's dlopen/dlsym loader expects.
// `nonisolated(unsafe)` local is required because MainActor.assumeIsolated
// cannot return an UnsafeMutableRawPointer directly (not Sendable).

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(SpecWidget())
    }
    return result
}
