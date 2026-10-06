// Widget.swift — task42's QA widget (task42-plugin-conversion, c7).
//
// Read-only: renders `qa/report` as themed markdown. Reproduces the live
// qaWidgetContent (SessionDetailPanel.swift) modulo one deliberate
// simplification: the built-in's `QAReportSegmentsView` (per-`### flow:
// <slug>` segment parsing) is an app-internal component, not promoted into
// the SDK — out of scope here, per this subtask's own description. Plain
// themed markdown (`Markdown(_:).markdownTheme(.work42)`) reads the same
// report content; only the segment-by-segment visual breakdown is absent.
//
// STORAGE: storageNamespace defaults to the widget's own slug ("qa"),
// which is exactly the namespace this widget reads from — no override
// needed.
//   qa/report — the QA report markdown, written by the QA agent
//               (`work42 qa <id> --report <md> ...`).

import Observation
import SwiftUI
import Work42PluginKit

@Observable
@MainActor
final class QAWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "qa"
    let title = "QA"
    let icon = "testtube.2"
    var linkIntents: [WidgetLinkIntentSpec] { [] }

    // MARK: - Observed state

    var report: String?

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
        AnyView(QAWidgetView(widget: self))
    }

    // MARK: - Storage

    func load() async {
        guard let services else { return }
        let value = (try? await services.storage.get(namespace: "qa", key: "report")) ?? nil
        if case .string(let text)? = value {
            report = text
        } else {
            report = nil
        }
    }
}

// MARK: - QAWidgetView

private struct QAWidgetView: View {
    let widget: QAWidget

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DT.s12) {
                if let report = widget.report, !report.isEmpty {
                    Markdown(report)
                        .markdownTheme(.work42)
                } else {
                    Text("No QA report yet")
                        .font(.system(size: DT.f13, weight: .semibold))
                    Text("QA writes its report to the session's `qa/report` storage. It renders here as it lands.")
                        .font(.system(size: DT.f11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DT.s8)
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
        result = WidgetEntryPoint.register(QAWidget())
    }
    return result
}
