// Widget.swift — linear42's Issue widget.
//
// Renders the Linear issue(s) attached to this session in a BrowserSurface with ONE TAB PER ISSUE (the
// user's normal linear.app web login; no token handling in Swift). Sub-issues and comments are visible
// natively on that page. An issue link handed over by Open Link that isn't attached opens as a temporary
// tab with an "Attach WOR-9 to this session?" bar; closing an attached tab asks before detaching it.
//
//   UNBOUND — Attach form: paste a key (WOR-123) or an issue URL.
//   BOUND   — BrowserSurface with a tab per attached issue, plus notice bars for CLI problems.
//   NO CONFIG / BAD CONFIG — a "linear42 isn't configured" notice naming the reason.
//
// STORAGE (storageNamespace "linear"; the view's services write here):
//   linear/issue_keys     — JSON array of the attached issue keys (Attach appends, Detach removes).
//   linear/issue_ref      — string: key or URL that SEEDS the first issue (the `issue` create arg,
//                           My Linear issues, the Attach form). Ignored once issue_keys is non-empty.
//   linear/issues/<KEY>/issue — {key,id,url,team,title}: resolved by the sync agent.
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
    let title = "Issue Details"
    let icon = "list.bullet.rectangle"
    /// The Linear logo in the + Widget menu, the tab and the header; the symbol above is the fallback.
    var iconImageData: Data? { linearIconPNG }
    var storageNamespace: String? { "linear" }
    /// Links to this widget's pages open here (the tab is focused) instead of navigating the page they
    /// were clicked in. A link to the page already shown only focuses the tab.
    var linkIntents: [WidgetLinkIntentSpec] {
        [
            WidgetLinkIntentSpec(
                matchers: [.regex(linearIssueLinkPattern)],
                perform: { [weak self] url in self?.openLink(url) }
            ),
        ]
    }

    // MARK: Observed state

    var config: Result<Linear42Config, Linear42Config.LoadError> = Linear42Config.load()
    var issueRef: String?
    /// The attached issue keys, in order (`linear/issue_keys`; the seed `issue_ref` until the agent writes it).
    var attachedKeys: [String] = []
    /// Resolved snapshots by key, for the pages' canonical URLs.
    var snapshots: [String: LinearIssueSnapshot] = [:]
    /// Issues opened through a link but not attached, with the URL that was clicked.
    var temporary: [(key: String, url: URL)] = []
    /// The temporary issue whose "Attach?" bar is showing.
    var attachPromptKey: String?
    /// The attached issue whose tab was closed and awaits the detach confirmation.
    var pendingDetachKey: String?
    var resolveError: String?
    var cliError: String?
    var isLoading = false
    @ObservationIgnored var browserModel: BrowserWidgetModel?
    @ObservationIgnored private var tabIDs: [String: UUID] = [:]

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
        var keys: [String] = []
        if case .array(let items)? = await read("issue_keys") {
            keys = parseKeyList(items.map { item -> Any in
                if case .string(let s) = item { return s }
                return NSNull()
            })
        }
        // Until the agent has written issue_keys (or migrated a single-issue session), the seed shows.
        if keys.isEmpty, let ref, let key = linearIssueKey(from: ref) { keys = [key] }
        var latest: [String: LinearIssueSnapshot] = [:]
        for key in keys {
            if let snapshot = LinearIssueSnapshot(await read("issues/\(key)/issue")) { latest[key] = snapshot }
        }
        let resolveErr = string(await read("resolve_error"))
        let cliErr = string(await read("cli_error"))
        if ref != issueRef { issueRef = ref }
        let snapshotsChanged = latest != snapshots
        if snapshotsChanged { snapshots = latest }
        if keys != attachedKeys {
            attachedKeys = keys
            temporary.removeAll { keys.contains($0.key) }
            syncTabs()
        } else if snapshotsChanged {
            syncTabs()
        }
        if resolveErr != resolveError { resolveError = resolveErr }
        if cliErr != cliError { cliError = cliErr }
    }

    // MARK: Tabs

    func stableTabID(for key: String) -> UUID {
        if let existing = tabIDs[key] { return existing }
        let new = UUID()
        tabIDs[key] = new
        return new
    }

    private func key(forTab tabID: UUID) -> String? {
        tabIDs.first(where: { $0.value == tabID })?.key
    }

    /// The page a tab shows: the clicked URL for a temporary tab, else the resolved issue URL, else the
    /// canonical URL built from the key and the configured workspace (so the page loads before the CLI
    /// resolved it).
    func pageURL(forKey key: String) -> URL? {
        if let temp = temporary.first(where: { $0.key == key }) { return temp.url }
        if let snapshot = snapshots[key], let url = URL(string: snapshot.url) { return url }
        guard case .success(let cfg) = config else { return nil }
        return URL(string: linearIssueURL(workspace: cfg.workspace, key: key))
    }

    var displayedTabKeys: [String] {
        displayedKeys(attached: attachedKeys, temporary: temporary.map(\.key))
    }

    /// One tab per attached issue, then the temporary ones (a dashed icon marks them as not attached).
    func syncTabs() {
        guard let model = browserModel else { return }
        let tabs = displayedTabKeys.compactMap { key -> BrowserTab? in
            guard let url = pageURL(forKey: key) else { return nil }
            let attached = attachedKeys.contains(key)
            return BrowserTab(id: stableTabID(for: key), url: url, title: key,
                              icon: attached ? "list.bullet.rectangle" : "circle.dashed")
        }
        model.replaceTabs(tabs)
    }

    /// Open Link handed this widget an issue URL: select an attached issue's tab, or open a temporary tab
    /// and ask whether to attach it.
    func openLink(_ url: URL) {
        guard let key = linearIssueKey(from: url.absoluteString) else { return }
        switch issueLinkAction(key: key, attached: attachedKeys, temporary: temporary.map(\.key)) {
        case .select:
            break
        case .openTemporary:
            temporary.removeAll { $0.key == key }
            temporary.append((key: key, url: url))
            attachPromptKey = key
        }
        syncTabs()
        browserModel?.selectTab(stableTabID(for: key))
    }

    /// The user closed `tabID`'s tab: confirm a detach, refuse the last attached issue, drop a temporary tab.
    func tabClosed(_ tabID: UUID) {
        guard let key = key(forTab: tabID) else { return }
        switch canClose(key: key, attached: attachedKeys) {
        case .dropTemporary:
            temporary.removeAll { $0.key == key }
            if attachPromptKey == key { attachPromptKey = nil }
            tabIDs.removeValue(forKey: key)
            syncTabs()
        case .confirmDetach:
            pendingDetachKey = key
            syncTabs() // bring the tab back until the user confirms
        case .refuse:
            syncTabs()
        }
    }

    // MARK: Derived

    /// The CLI problem to surface above the page, if any.
    var cliNotice: String? {
        switch cliError {
        case "missing"?: return "The linear CLI isn't installed. Run: brew install schpet/tap/linear"
        case "auth"?: return "The linear CLI isn't signed in. Run: linear auth login"
        default: return nil
        }
    }

    // MARK: Actions

    /// Seeds the session's first issue (the unbound Attach form). Returns an error string, or nil on success.
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

    /// Attaches a temporary issue: appends it to `linear/issue_keys`; its tab becomes permanent.
    func attachTemporary(_ key: String) async {
        guard let services else { return }
        let updated = appendingKey(attachedKeys, key)
        do {
            try await services.storage.set(key: "issue_keys", value: .array(updated.map { .string($0) }))
        } catch { return }
        attachedKeys = updated
        temporary.removeAll { $0.key == key }
        attachPromptKey = nil
        syncTabs()
        browserModel?.selectTab(stableTabID(for: key))
    }

    func dismissAttachPrompt() { attachPromptKey = nil }

    /// Detaches an attached issue after the user confirmed: removes the key and its `linear/issues/<KEY>/*`
    /// values; the sync drops its sub-issues from `plan/subtasks` on the next poll. Linear is untouched.
    func confirmDetach() async {
        guard let services, let key = pendingDetachKey else { return }
        pendingDetachKey = nil
        let updated = removingKey(attachedKeys, key)
        guard updated != attachedKeys else { return }
        do {
            try await services.storage.set(key: "issue_keys", value: .array(updated.map { .string($0) }))
        } catch { return }
        for name in flatIssueKeyNames { try? await services.storage.delete(key: "issues/\(key)/\(name)") }
        attachedKeys = updated
        snapshots.removeValue(forKey: key)
        tabIDs.removeValue(forKey: key)
        syncTabs()
    }

    func cancelDetach() { pendingDetachKey = nil }

    /// Clears an unresolved seed so a different issue can be attached (the "not found" screen).
    func detach() async {
        guard let services else { return }
        for key in ["issue_ref", "resolve_error"] {
            try? await services.storage.delete(key: key)
        }
        issueRef = nil
        attachedKeys = []
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
        } else if let first = widget.displayedTabKeys.first, let url = widget.pageURL(forKey: first) {
            VStack(spacing: 0) {
                if let key = widget.attachPromptKey,
                   widget.browserModel?.activeTabId == widget.stableTabID(for: key) {
                    LinearAttachBar(key: key, widget: widget)
                }
                BrowserSurface(
                    spec: BrowserSurfaceSpec(
                        url: url,
                        // No isolation selector: it blanks the page when signed out.
                        selector: "",
                        // Shared cookie store with the regular Browser widget.
                        dataStoreKey: "browser",
                        title: "Issue Details",
                        icon: "list.bullet.rectangle"
                    ),
                    cacheKey: widget.id,
                    configure: { [weak widget] model in
                        guard let widget else { return }
                        widget.browserModel = model
                        widget.syncTabs()
                        // The chrome's + has nothing to add: issues attach from Open Link or the Planner.
                        model.onNewTab = {}
                        model.onTabClosed = { [weak widget] tabID in widget?.tabClosed(tabID) }
                    }
                )
            }
            .alert(
                "Detach \(widget.pendingDetachKey ?? "") from this session?",
                isPresented: Binding(
                    get: { widget.pendingDetachKey != nil },
                    set: { if !$0 { widget.cancelDetach() } }
                )
            ) {
                Button("Cancel", role: .cancel) { widget.cancelDetach() }
                Button("Detach", role: .destructive) { Task { await widget.confirmDetach() } }
            } message: {
                Text("Its sub-issues leave the subtask list and its status stops syncing. Nothing changes in Linear.")
            }
        } else {
            LinearAttachForm(widget: widget)
        }
    }
}

@MainActor
private struct LinearAttachBar: View {
    let key: String
    let widget: LinearIssueWidget

    var body: some View {
        HStack(spacing: DT.s8) {
            LinearBrandMark(size: 14)
            Text("Attach **\(key)** to this session?")
                .font(.system(size: DT.f12))
            Spacer(minLength: 0)
            Button("Not now") { widget.dismissAttachPrompt() }
            Button("Attach") { Task { await widget.attachTemporary(key) } }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, DT.s12)
        .padding(.vertical, DT.s8)
        .background(Color(red: 0.37, green: 0.42, blue: 0.82).opacity(0.14))
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
