// Widget.swift — task42's Testing Plan widget (task42-plugin-conversion, c8).
//
// Read-only: renders `plan/testing` as a themed, comment-integrated
// markdown document via Work42UI's Work42MarkdownDocument (s6). Mirrors
// SessionDetailPanel's testingPlanWidgetContent/testingPlanDocument —
// same empty-state copy, same comment-pinning key (`<sessionId>/plan/testing`).
// The built-in does not wire artifact-embed resolution for the testing
// plan either, so `artifactsEnabled` is false here to match exactly.
//
// STORAGE (storageNamespace "plan" — shared with the spec/subtasks
// widgets and the workflow gates):
//   plan/testing — the testing-plan markdown, authored by the Planner↔QA
//                  dialogue (see the task42-planner/task42-qa skills).
// Markdown links such as
//   [login / browser](flow42://flow/login?variant=browser)
// remain ordinary links. Work42's generic Open Link resolver offers them to
// the Flow42 definition widget when installed; this widget imports no Flow42
// code and behaves identically when that optional plugin is absent.

import Observation
import SwiftUI
import Work42WidgetKit

@Observable
@MainActor
final class TestingPlanWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "testing-plan"
    let title = "Testing Plan"
    let icon = "list.bullet.rectangle"
    var storageNamespace: String? { "plan" }
    var linkIntents: [WidgetLinkIntentSpec] { [] }

    // MARK: - Observed state

    var plan: String?

    private var services: SessionServices?

    // MARK: - Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        Task { @MainActor [weak self] in
            await self?.load()
        }
    }

    func deactivate() {
        services = nil
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(TestingPlanWidgetView(widget: self, services: services))
    }

    // MARK: - Storage

    func load() async {
        guard let services else { return }
        let value = (try? await services.storage.get(namespace: "plan", key: "testing")) ?? nil
        if case .string(let text)? = value {
            plan = text
        } else {
            plan = nil
        }
    }
}

// MARK: - TestingPlanWidgetView

private struct TestingPlanWidgetView: View {
    let widget: TestingPlanWidget
    let services: SessionServices

    var body: some View {
        Group {
            if let plan = widget.plan, !plan.isEmpty {
                Work42MarkdownDocument(
                    text: plan,
                    sessionId: services.sessionId,
                    commentKey: "plan/testing",
                    artifactsEnabled: false,
                    baseURL: services.worktreePath.map { URL(fileURLWithPath: $0) }
                )
            } else {
                VStack(alignment: .leading, spacing: DT.s8) {
                    Text("No testing plan yet")
                        .font(.system(size: DT.f13, weight: .semibold))
                    Text("Author one with `work42 storage set plan/testing`. It'll appear here automatically.")
                        .font(.system(size: DT.f11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DT.s12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { await widget.load() }
    }
}

// MARK: - Widget entry-point ABI

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(TestingPlanWidget())
    }
    return result
}
