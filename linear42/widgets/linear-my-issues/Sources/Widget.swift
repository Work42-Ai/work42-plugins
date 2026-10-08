// Widget.swift — linear42's "My Linear Issues" widget.
//
// A Home-surface browser widget on the user's assigned issues
// (https://linear.app/<workspace>/my-issues/assigned, workspace from
// ~/.config/linear42/config.json) plus one action: "Start Linear Session" —
// opens a new linear-task session bound to the issue currently showing.
//
// No credentials: authentication is the shared browser login (dataStoreKey
// "browser"); sign in to Linear once and the cookie store persists.
//
// ACTION-AREA INTENT: "start-linear-session"
//   isEnabled: true whenever the page names a Linear issue (an /issue/<KEY>/… page,
//              or an issue opened from the list).
//   perform:   services.intents.execute(id: "session.open", …) seeds the new
//              session's `linear/issue_ref` with the issue key, so its Issue tab
//              loads that issue immediately.
//
// Linear42Config.swift / Linear42Logic.swift are verbatim copies of the
// linear-issue widget's (widgets compile independently and cannot share a module);
// Tests/LogicTests/run.sh fails if the copies drift.

import Foundation
import Observation
import SwiftUI
import Work42PluginKit

@Observable
@MainActor
final class LinearMyIssuesWidget: Work42Widget {

    // MARK: Work42Widget conformance

    let id = "linear-my-issues"
    let title = "My Linear Issues"
    let icon = "list.bullet.rectangle"
    /// The Linear logo in the + Widget menu, the tab and the header; the symbol above is the fallback.
    var iconImageData: Data? { linearIconPNG }

    /// A dashboard that starts sessions; not a link destination.
    let linkIntents: [WidgetLinkIntentSpec] = []

    // MARK: Observed state

    /// Re-read from ~/.config/linear42/config.json on every refresh — never cached.
    var config: Result<Linear42Config, Linear42Config.LoadError> = Linear42Config.load()

    // MARK: Internal

    private var services: SessionServices?

    /// Stashed from the BrowserSurface `configure:` closure so the action-area intent
    /// can read the page URL. Ignored by observation: the model is @Observable itself.
    @ObservationIgnored
    fileprivate var browserModel: BrowserWidgetModel?

    // MARK: Intents

    var intents: [WidgetIntentSpec] {
        [
            WidgetIntentSpec(
                name: "start-linear-session",
                title: "Start Linear Session",
                icon: "play.circle",
                keywords: ["linear", "issue", "session", "start", "task"],
                placement: [.actionArea, .palette],
                actionAreaStyle: .labeled,
                isEnabled: { [weak self] in
                    guard let self else { return false }
                    return linearIssueKey(from: currentURL) != nil
                },
                perform: { [weak self] in
                    guard let self, let services = self.services,
                          let key = linearIssueKey(from: currentURL)
                    else { return }
                    let launch = await Self.sessionLaunch(forKey: key, services: services)
                    var params: [String: WidgetJSONValue] = [
                        "typeId": .string("linear-task"),
                        "name": .string(launch.name),
                        "initialWidgetStorage": .object([
                            "linear": .object(["issue_ref": .string(key)]),
                        ]),
                    ]
                    // The branch Linear suggests for the issue, so its GitHub integration links the PR.
                    if let branch = launch.branchName { params["branchName"] = .string(branch) }
                    try await services.intents.execute(id: "session.open", params: params)
                }
            ),
        ]
    }

    private var currentURL: String {
        browserModel?.urlDraft ?? BrowserSurface.model(forKey: id)?.urlDraft ?? ""
    }

    /// `"<KEY>: <title>"` and Linear's `branchName` from one fail-soft `linear api` lookup, else the bare
    /// key and no branch: a nicer name and branch when the CLI answers, never blocking or failing the launch.
    private static func sessionLaunch(forKey key: String, services: SessionServices) async -> LinearSessionLaunch {
        let query = "query($id: String!) { issue(id: $id) { title branchName } }"
        let variables = "{\"id\":\"\(key)\"}"
        let command = linearCLIPathPrefix + "linear api \(shellQuote(query)) --variables-json \(shellQuote(variables))"
        let result = try? await services.shell.run(command: command)
        return linearSessionLaunch(key: key, apiOutput: result?.exitCode == 0 ? result?.stdout : nil)
    }

    // MARK: Lifecycle

    func activate(services: SessionServices) {
        self.services = services
    }

    func deactivate() {
        services = nil
        browserModel = nil
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(LinearMyIssuesView(widget: self))
    }

    func refreshConfig() {
        let latest = Linear42Config.load()
        if latest != config { config = latest }
    }
}

// MARK: - View

@MainActor
private struct LinearMyIssuesView: View {
    let widget: LinearMyIssuesWidget

    var body: some View {
        Group {
            switch widget.config {
            case .failure(let error):
                VStack(spacing: DT.s12) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(DT.textTertiary)
                    Text("linear42 isn't configured")
                        .font(.system(size: DT.f13, weight: .medium))
                    Text(error.message)
                        .font(.system(size: DT.f11))
                        .foregroundStyle(.secondary)
                    Text("Create ~/.config/linear42/config.json with \"workspace\" and \"default_team\".")
                        .font(.system(size: DT.f11))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(DT.s24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .success(let config):
                if let url = myIssuesURL(workspace: config.workspace) {
                    BrowserSurface(
                        spec: BrowserSurfaceSpec(
                            url: url,
                            selector: "",
                            // Shared cookie store with the regular Browser widget — sign in once.
                            dataStoreKey: "browser",
                            title: "Linear",
                            icon: "list.bullet.rectangle"
                        ),
                        cacheKey: widget.id,
                        configure: { [weak widget] model in widget?.browserModel = model }
                    )
                    .id(url.absoluteString)
                }
            }
        }
        // Config edits (e.g. a changed workspace) apply without reopening the tab.
        .task {
            while !Task.isCancelled {
                widget.refreshConfig()
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
            }
        }
    }

    private func myIssuesURL(workspace: String) -> URL? {
        let ws = workspace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? workspace
        return URL(string: "https://linear.app/\(ws)/my-issues/assigned")
    }
}

// MARK: - Widget entry-point ABI

@_cdecl("work42_widget_sdk_version")
public func work42_widget_sdk_version() -> Int32 { WidgetSDK.abiVersion }

@_cdecl("work42_widget_main")
public func work42_widget_main() -> UnsafeMutableRawPointer {
    nonisolated(unsafe) var result: UnsafeMutableRawPointer!
    MainActor.assumeIsolated {
        result = WidgetEntryPoint.register(LinearMyIssuesWidget())
    }
    return result
}
