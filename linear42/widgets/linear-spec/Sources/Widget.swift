// Widget.swift — linear42's Spec widget.
//
// Renders the spec as the Linear Document the Planner attached to the issue
// (`linear/spec_doc`), in a BrowserSurface on the user's linear.app login, and
// owns the Approve Plan action — the human gate between Planning and In-Progress.
//
// STORAGE (storageNamespace "plan"):
//   linear/spec_doc   — {slug,url}. Read-only here; written by the Planner.
//   plan/subtasks     — the sub-issue mirror. Read-only here; Approve needs it non-empty.
//   plan/approved_at  — ISO-8601; written by Approve Plan (the In-Progress gate's signal).
//   plan/approved_by  — the approver's macOS username; written by Approve Plan.
//
// Approve writes the two local keys through the `work42` CLI (session-scoped; also
// re-checks the gates, which posts the "In-Progress is now available" message).
// It deliberately does NOT touch Linear: the sync agent is the single writer to
// Linear and stamps the approval (comment + In-Progress state) within one poll,
// which keeps two writers from racing and double-commenting.

import Foundation
import Observation
import SwiftUI
import Work42PluginKit

/// `linear/spec_doc` / `linear/testing_doc` — a Linear document reference.
struct LinearDocRef: Equatable, Sendable {
    var slug: String
    var url: URL

    init?(_ value: WidgetJSONValue?) {
        guard case .object(let o)? = value,
              case .string(let raw)? = o["url"], let url = URL(string: raw)
        else { return nil }
        self.url = url
        if case .string(let slug)? = o["slug"] { self.slug = slug } else { self.slug = "" }
    }
}

@Observable
@MainActor
final class LinearSpecWidget: Work42Widget {

    // MARK: Work42Widget conformance

    let id = "linear-spec"
    let title = "Spec Document"
    let icon = "doc.text"
    /// The Linear logo in the + Widget menu, the tab and the header; the symbol above is the fallback.
    var iconImageData: Data? { linearIconPNG }
    var storageNamespace: String? { "plan" }
    /// Links to this widget's pages open here (the tab is focused) instead of navigating the page they
    /// were clicked in. A link to the page already shown only focuses the tab.
    var linkIntents: [WidgetLinkIntentSpec] {
        [
            WidgetLinkIntentSpec(
                matchers: [.regex(linearSpecDocLinkPattern)],
                perform: { [weak self] url in self?.openLink(url) }
            ),
        ]
    }

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
                    return canApprove
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

    // MARK: Observed state

    var specDoc: LinearDocRef?
    /// A document opened through a link (a different Spec page than the stored one); nil shows `specDoc`.
    var openedURL: URL?
    var hasSubIssues = false
    var isApproved = false
    var isApproving = false
    var errorMessage: String?

    /// Approve needs a spec doc and at least one sub-issue, and is one-shot.
    var canApprove: Bool { specDoc != nil && hasSubIssues && !isApproved && !isApproving }

    private var services: SessionServices?

    // MARK: Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        Task { @MainActor [weak self] in await self?.refresh() }
    }

    func deactivate() {
        services = nil
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(LinearSpecView(widget: self))
    }

    func openLink(_ url: URL) {
        openedURL = linkDestination(url, current: specDoc?.url)
    }

    // MARK: Storage (assign only on change)

    func refresh() async {
        guard let services else { return }
        let doc = LinearDocRef((try? await services.storage.get(namespace: "linear", key: "spec_doc")) ?? nil)
        var nonEmpty = false
        if case .array(let rows)? = (try? await services.storage.get(namespace: "plan", key: "subtasks")) ?? nil {
            nonEmpty = !rows.isEmpty
        }
        let approved = ((try? await services.storage.get(namespace: "plan", key: "approved_at")) ?? nil) != nil
        if doc != specDoc { specDoc = doc; openedURL = nil }
        if nonEmpty != hasSubIssues { hasSubIssues = nonEmpty }
        if approved != isApproved { isApproved = approved }
    }

    // MARK: Approve

    private func approvePlan(services: SessionServices) async {
        guard canApprove else { return }
        isApproving = true
        errorMessage = nil
        defer { isApproving = false }
        let now = ISO8601DateFormatter().string(from: Date())
        // approved_by first: approved_at is the gate signal, and its write posts the nudge.
        for (key, value) in [("approved_by", NSUserName()), ("approved_at", now)] {
            let command = "work42 storage set plan/\(key) \(shellQuote(jsonString(value)))"
            guard let result = try? await services.shell.run(command: command), result.exitCode == 0 else {
                errorMessage = "Couldn't write plan/\(key). Is the work42 CLI available?"
                return
            }
        }
        isApproved = true
    }

    private func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return text
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - View

@MainActor
private struct LinearSpecView: View {
    let widget: LinearSpecWidget

    var body: some View {
        VStack(spacing: 0) {
            if let message = widget.errorMessage {
                HStack(spacing: DT.s8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.system(size: DT.f11))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DT.s12)
                .padding(.vertical, DT.s8)
                .background(Color.orange.opacity(0.12))
            }
            if let doc = widget.specDoc {
                let shown = widget.openedURL ?? doc.url
                BrowserSurface(
                    spec: BrowserSurfaceSpec(
                        url: shown,
                        selector: "",
                        dataStoreKey: "browser",
                        title: "Spec Document",
                        icon: "doc.text"
                    ),
                    cacheKey: widget.id
                )
                .id(shown.absoluteString)
            } else {
                VStack(alignment: .leading, spacing: DT.s8) {
                    LinearBrandMark(size: 28)
                    Text("No spec yet")
                        .font(.system(size: DT.f13, weight: .semibold))
                    Text("The Planner creates the spec as a Linear document on the issue. It appears here once it exists; then approve the plan.")
                        .font(.system(size: DT.f12))
                        .foregroundStyle(DT.textSecondary)
                }
                .padding(DT.s16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // Live refresh while on screen: the Planner's `linear/spec_doc` write and the
        // sync agent's `plan/subtasks` mirror enable Approve without reopening the tab.
        .task {
            await widget.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                if Task.isCancelled { break }
                await widget.refresh()
            }
        }
    }
}

// MARK: - Widget entry-point ABI

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(LinearSpecWidget())
    }
    return result
}
