// Widget.swift — linear42's Issue widget.
//
// Renders the Linear issue bound to this session in a BrowserSurface (the
// user's normal linear.app web login; no token handling in Swift). Sub-issues
// and comments are visible natively on that page.
//
//   UNBOUND — Attach form: paste a key (WOR-123) or an issue URL.
//   BOUND   — BrowserSurface on the issue page, plus notice bars for CLI problems.
//   NO CONFIG / BAD CONFIG — a "linear42 isn't configured" notice naming the reason.
//
// STORAGE (storageNamespace "linear"; the view's services write here):
//   linear/issue_ref      — string: key or URL the session is bound to. Seeded by the
//                           `issue` create arg / My Linear issues, or written by Attach.
//   linear/issue          — {key,id,url,team,title}: resolved by the sync agent (s3).
//   linear/resolve_error  — "not_found" when the CLI cannot find issue_ref.
//   linear/cli_error      — "missing" | "auth": the linear CLI problem, set by the agent.
// The full key list lives in SKILL.md. The header chips and the Linear sync are
// published by the per-session background agent, never by this widget instance
// (the host reads widget-level header labels from a shared singleton).

import Observation
import SwiftUI
import Work42PluginKit

// MARK: - Resolved issue

/// `linear/issue` — written by the sync agent once the CLI resolved the ref.
struct LinearIssueSnapshot: Equatable, Sendable {
    var key: String
    var id: String
    var url: String
    var team: String
    var title: String

    init?(_ value: WidgetJSONValue?) {
        guard case .object(let o)? = value,
              case .string(let key)? = o["key"], !key.isEmpty,
              case .string(let url)? = o["url"], !url.isEmpty
        else { return nil }
        func str(_ k: String) -> String { if case .string(let s)? = o[k] { return s }; return "" }
        self.key = key
        self.url = url
        self.id = str("id")
        self.team = str("team")
        self.title = str("title")
    }
}

// MARK: - LinearIssueWidget

@Observable
@MainActor
final class LinearIssueWidget: Work42Widget {

    // MARK: Work42Widget conformance

    let id = "linear-issue"
    let title = "Linear"
    let icon = "list.bullet.rectangle"
    /// The Linear logo in the + Widget menu, the tab and the header; the symbol above is the fallback.
    var iconImageData: Data? { linearIconPNG }
    var storageNamespace: String? { "linear" }
    var linkIntents: [WidgetLinkIntentSpec] { [] }

    // MARK: Observed state

    var config: Result<Linear42Config, Linear42Config.LoadError> = Linear42Config.load()
    var issueRef: String?
    var issue: LinearIssueSnapshot?
    var resolveError: String?
    var cliError: String?
    var isLoading = false

    private var services: SessionServices?

    // MARK: Lifecycle

    func activate(services: SessionServices) {
        self.services = services
        isLoading = true
        Task { @MainActor [weak self] in
            await self?.refresh()
            self?.isLoading = false
        }
    }

    func deactivate() {
        services = nil
        isLoading = false
        BrowserSurfaceCache.shared.teardown(key: id)
    }

    func makeView(services: SessionServices) -> AnyView {
        AnyView(LinearIssueMainView(widget: self, services: services))
    }

    // MARK: Storage (read live; assign only on change so views never thrash)

    func refresh() async {
        // Config is re-read on every cycle — never cached.
        let latestConfig = Linear42Config.load()
        if latestConfig != config { config = latestConfig }

        guard let services else { return }
        func read(_ key: String) async -> WidgetJSONValue? {
            (try? await services.storage.get(namespace: "linear", key: key)) ?? nil
        }
        func string(_ v: WidgetJSONValue?) -> String? {
            if case .string(let s)? = v, !s.isEmpty { return s }
            return nil
        }
        let ref = string(await read("issue_ref"))
        let resolved = LinearIssueSnapshot(await read("issue"))
        let resolveErr = string(await read("resolve_error"))
        let cliErr = string(await read("cli_error"))
        if ref != issueRef { issueRef = ref }
        if resolved != issue { issue = resolved }
        if resolveErr != resolveError { resolveError = resolveErr }
        if cliErr != cliError { cliError = cliErr }
    }

    // MARK: Derived

    /// The page to show: the resolved issue URL, else the canonical URL built from
    /// the ref + configured workspace (so the page loads before the CLI resolved it).
    var pageURL: URL? {
        if let issue, let url = URL(string: issue.url) { return url }
        guard let ref = issueRef, let key = linearIssueKey(from: ref),
              case .success(let cfg) = config
        else { return nil }
        return URL(string: linearIssueURL(workspace: cfg.workspace, key: key))
    }

    /// The CLI problem to surface above the page, if any.
    var cliNotice: String? {
        switch cliError {
        case "missing"?: return "The linear CLI isn't installed. Run: brew install schpet/tap/linear"
        case "auth"?: return "The linear CLI isn't signed in. Run: linear auth login"
        default: return nil
        }
    }

    // MARK: Actions

    /// Binds the session to an issue. Returns an error string, or nil on success.
    func attach(input: String) async -> String? {
        guard let key = linearIssueKey(from: input) else {
            return "Not a Linear issue. Enter a key like WOR-123 or an issue URL."
        }
        guard let services else { return "Widget not active." }
        do {
            try await services.storage.set(key: "issue_ref", value: .string(key))
            try? await services.storage.delete(key: "resolve_error")
        } catch {
            return "Failed to bind the issue: \(error.localizedDescription)"
        }
        issueRef = key
        resolveError = nil
        return nil
    }

    /// Clears the binding so a different issue can be attached.
    func detach() async {
        guard let services else { return }
        for key in ["issue_ref", "issue", "resolve_error"] {
            try? await services.storage.delete(key: key)
        }
        issueRef = nil
        issue = nil
        resolveError = nil
    }
}

// MARK: - Views

@MainActor
private struct LinearIssueMainView: View {
    let widget: LinearIssueWidget
    let services: SessionServices

    var body: some View {
        VStack(spacing: 0) {
            if let notice = widget.cliNotice {
                LinearNoticeBar(text: notice)
            }
            content
        }
        // Live refresh while the tab is on screen: agent/CLI writes to the linear/*
        // keys (and edits to config.json) land without reopening the tab.
        .task {
            await widget.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s
                if Task.isCancelled { break }
                await widget.refresh()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .failure(let error) = widget.config {
            LinearConfigNotice(error: error)
        } else if widget.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if widget.resolveError == "not_found", let ref = widget.issueRef {
            LinearNotFoundView(widget: widget, ref: ref)
        } else if let url = widget.pageURL {
            BrowserSurface(
                spec: BrowserSurfaceSpec(
                    url: url,
                    // No isolation selector: it blanks the page when signed out.
                    selector: "",
                    // Shared cookie store with the regular Browser widget.
                    dataStoreKey: "browser",
                    title: "Linear",
                    icon: "list.bullet.rectangle"
                ),
                cacheKey: widget.id
            )
        } else {
            LinearAttachForm(widget: widget)
        }
    }
}

@MainActor
private struct LinearNoticeBar: View {
    let text: String

    var body: some View {
        HStack(spacing: DT.s8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: DT.f11))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DT.s12)
        .padding(.vertical, DT.s8)
        .background(Color.orange.opacity(0.12))
    }
}

@MainActor
private struct LinearConfigNotice: View {
    let error: Linear42Config.LoadError

    var body: some View {
        VStack(spacing: DT.s12) {
            Image(systemName: "gearshape")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DT.textTertiary)
            Text("linear42 isn't configured")
                .font(.system(size: DT.f13, weight: .medium))
            Text(error.message)
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
            Text("Create ~/.config/linear42/config.json:")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
            Text("{ \"workspace\": \"<linear.app workspace>\", \"default_team\": \"<TEAM KEY>\" }")
                .font(.system(size: DT.f11, design: .monospaced))
                .textSelection(.enabled)
        }
        .multilineTextAlignment(.center)
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct LinearNotFoundView: View {
    let widget: LinearIssueWidget
    let ref: String

    var body: some View {
        VStack(spacing: DT.s12) {
            Text("Issue \(ref) not found")
                .font(.system(size: DT.f13, weight: .medium))
            Text("The linear CLI couldn't find it. Check the key, or pick another issue.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
            Button("Choose another issue") {
                Task { await widget.detach() }
            }
        }
        .multilineTextAlignment(.center)
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private struct LinearAttachForm: View {
    let widget: LinearIssueWidget

    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var attaching = false

    var body: some View {
        VStack(spacing: DT.s16) {
            LinearBrandMark(size: 40)
            Text("No Linear issue")
                .font(.system(size: DT.f13, weight: .medium))
            Text("Enter an issue key or paste its URL to bind this session. Or leave it unbound and the Planner will create the issue. Sign in to Linear once and the session is kept.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: DT.s8) {
                TextField("WOR-123 or https://linear.app/…/issue/WOR-123", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Attach", action: submit)
                    .disabled(attaching || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(maxWidth: 420)
            if let message = errorMessage {
                Text(message)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        let input = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !attaching else { return }
        attaching = true
        errorMessage = nil
        Task { @MainActor in
            defer { attaching = false }
            if let error = await widget.attach(input: input) {
                errorMessage = error
            } else {
                draft = ""
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
        result = WidgetEntryPoint.register(LinearIssueWidget())
    }
    return result
}
