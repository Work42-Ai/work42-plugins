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
//                        agent via `work42 storage set plan/spec`.
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

    var intents: [WidgetIntentSpec] {
        [
            WidgetIntentSpec(
                name: "approvePlan",
                title: "Approve Plan",
                icon: "checkmark.seal.fill",
                placement: [.palette, .actionArea],
                actionAreaStyle: .labeled,
                isEnabled: { [weak self] in
                    guard let self else { return false }
                    return hasSpec && !isApproving && !isApproved
                },
                isConfirmed: { [weak self] in self?.isApproved ?? false },
                actionAreaTitle: { [weak self] in
                    guard let self else { return "Approve Plan" }
                    if isApproving { return "Approving…" }
                    if isApproved { return "Plan approved" }
                    return "Approve Plan"
                },
                performWithServices: { [weak self] services in
                    await self?.approvePlan(services: services)
                }
            ),
        ]
    }

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
        if case .string(let text)? = specValue {
            spec = text
        } else {
            spec = nil
        }
        let approvedAt = (try? await services.storage.get(namespace: "plan", key: "approved_at")) ?? nil
        isApproved = approvedAt != nil
    }

    private func approvePlan(services: SessionServices) async {
        guard !isApproving else { return }
        isApproving = true
        defer { isApproving = false }
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            try await services.storage.set(key: "approved_at", value: .string(now))
            try await services.storage.set(key: "approved_by", value: .string(NSUserName()))
            isApproved = true
        } catch {
            // Non-fatal — the button stays actionable; the palette surfaces
            // the failure from the intent invocation itself.
        }
    }
}

// MARK: - SpecWidgetView

private struct SpecWidgetView: View {
    let widget: SpecWidget
    let services: SessionServices

    var body: some View {
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
                    Text("Draft one with `work42 storage set plan/spec`, then approve it here.")
                        .font(.system(size: DT.f12))
                        .foregroundStyle(DT.textSecondary)
                }
                .padding(DT.s16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .task { await widget.load() }
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
