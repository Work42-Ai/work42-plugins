// Widget.swift — linear42's Spec widget.
//
// Renders the specs as the Linear Documents the Planner attached to the session's issues
// (`linear/issues/<KEY>/spec_doc`), one tab per document, in a BrowserSurface on the user's linear.app
// login, and owns the Approve Plan action — the human gate between Planning and In-Progress.
//
// STORAGE (storageNamespace "plan"):
//   linear/issue_keys              — the attached issue keys.
//   linear/issues/<KEY>/spec_doc   — {slug,url}. Read-only here; written by the Planner.
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
    /// Links to spec documents open here (the tab is focused and the document selected) instead of
    /// navigating the page they were clicked in.
    var linkIntents: [WidgetLinkIntentSpec] {
        [
            WidgetLinkIntentSpec(
                matchers: [.regex(linearSpecDocLinkPattern)],
                perform: { [weak self] url in self?.openLink(url) }
            ),
        ]
    }

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

    // MARK: Per person

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

    func canApprove(for who: WidgetCollaborator) -> Bool {
        !docs.isEmpty && hasSubIssues && !hasApproved(who) && !isApproving
    }

    // MARK: Observed state

    /// Documents the attached issues hold (`linear/issues/<KEY>/spec_doc`; an older single-issue session's flat
    /// `linear/spec_doc` has no key), in issue order.
    var docs: [(key: String?, url: URL)] = []
    /// Documents opened through a link that no attached issue holds.
    var temporary: [URL] = []
    @ObservationIgnored var browserModel: BrowserWidgetModel?
    @ObservationIgnored private var tabIDs: [String: UUID] = [:]

    /// One tab per stored document, then the temporary ones.
    var tabs: [DocumentTab] { documentTabs(stored: docs, temporary: temporary) }

    func stableTabID(for slugID: String) -> UUID {
        if let existing = tabIDs[slugID] { return existing }
        let new = UUID()
        tabIDs[slugID] = new
        return new
    }

    func syncTabs() {
        guard let model = browserModel else { return }
        model.replaceTabs(tabs.map { tab in
            BrowserTab(id: stableTabID(for: tab.slugID), url: tab.url,
                       title: documentTabTitle(emoji: "📐", kind: "Spec", key: tab.key),
                       icon: "doc.text")
        })
    }

    /// Open Link handed this widget a document URL: select its tab, or open it in a temporary one.
    func openLink(_ url: URL) {
        if !tabs.contains(where: { $0.url == url }) { temporary.append(url) }
        syncTabs()
        let slugID = documentSlugID(from: url) ?? url.absoluteString
        browserModel?.selectTab(stableTabID(for: slugID))
    }

    /// A tab was closed: a temporary one goes; a stored document's tab comes back (its issue still holds it).
    func tabClosed(_ tabID: UUID) {
        if let slugID = tabIDs.first(where: { $0.value == tabID })?.key,
           let tab = tabs.first(where: { $0.slugID == slugID }), !tab.stored {
            temporary.removeAll { (documentSlugID(from: $0) ?? $0.absoluteString) == slugID }
            tabIDs.removeValue(forKey: slugID)
        }
        syncTabs()
    }

    /// Reads the stored documents; assigns only on change so the view never re-renders for an unchanged poll.
    func refreshDocs(_ services: SessionServices) async {
        func read(_ key: String) async -> WidgetJSONValue? {
            (try? await services.storage.get(namespace: "linear", key: key)) ?? nil
        }
        var keys: [String] = []
        if case .array(let items)? = await read("issue_keys") {
            keys = items.compactMap { item in
                if case .string(let s) = item { return s }
                return nil
            }
        }
        var found: [(key: String?, url: URL)] = []
        for key in keys {
            if let doc = LinearDocRef(await read("issues/\(key)/spec_doc")) { found.append((key: key, url: doc.url)) }
        }
        if keys.isEmpty, let doc = LinearDocRef(await read("spec_doc")) { found.append((key: nil, url: doc.url)) }
        let changed = found.map(\.url) != docs.map(\.url) || found.map { $0.key ?? "" } != docs.map { $0.key ?? "" }
        guard changed else { return }
        docs = found
        temporary.removeAll { url in found.contains { $0.url == url } }
        syncTabs()
    }

    var hasSubIssues = false
    var isApproved = false
    var isApproving = false
    var errorMessage: String?

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

    // MARK: Storage (assign only on change)

    func refresh() async {
        guard let services else { return }
        await refreshDocs(services)
        var nonEmpty = false
        if case .array(let rows)? = (try? await services.storage.get(namespace: "plan", key: "subtasks")) ?? nil {
            nonEmpty = !rows.isEmpty
        }
        let approved = ((try? await services.storage.get(namespace: "plan", key: "approved_at")) ?? nil) != nil
        let owners = Set(((try? await services.storage.people(key: "approved")) ?? [:]).keys)
        let others = Set(((try? await services.storage.people(key: "reviewed")) ?? [:]).keys)
        if nonEmpty != hasSubIssues { hasSubIssues = nonEmpty }
        if approved != isApproved { isApproved = approved }
        if owners != approvers { approvers = owners }
        if others != reviewers { reviewers = others }
    }

    // MARK: Approve

    /// Records the acting person's own approval, and for the owner also the keys the In-Progress gate and the sync agent read.
    /// `services.actor` is whoever pressed the button, on this Mac or on another device.
    private func approvePlan(services: SessionServices) async {
        let who = services.actor
        guard canApprove(for: who) else { return }
        isApproving = true
        errorMessage = nil
        defer { isApproving = false }
        let now = ISO8601DateFormatter().string(from: Date())
        do {
            // Their own entry first: it is what the people-count gate reads, and only they can write it.
            try await services.storage.setPerson(key: key(for: who), value: .string(now))
        } catch {
            errorMessage = "Couldn't record your approval: \(error.localizedDescription)"
            return
        }
        if who.isOwner {
            // approved_by first: approved_at is the gate signal, and its write posts the nudge.
            for (key, value) in [("approved_by", who.displayName), ("approved_at", now)] {
                do {
                    _ = try await services.tools.call(
                        server: "work42-session", tool: "storage_set",
                        arguments: ["key": .string("plan/\(key)"), "value": .string(value)], session: nil)
                } catch {
                    errorMessage = "Couldn't write plan/\(key): \(error.localizedDescription)"
                    return
                }
            }
            isApproved = true
            approvers.insert(who.id)
        } else {
            reviewers.insert(who.id)
        }
    }

    /// Clears the acting person's own approval. When the owner takes theirs back, the legacy keys go too: the sync agent sees
    /// `plan/approved_at` gone while the approval is stamped on Linear, and posts the revoke comment there.
    private func revokeApproval(services: SessionServices) async {
        let who = services.actor
        errorMessage = nil
        do {
            try await services.storage.deletePerson(key: key(for: who))
        } catch {
            errorMessage = "Couldn't take back your approval: \(error.localizedDescription)"
            return
        }
        guard who.isOwner else {
            reviewers.remove(who.id)
            return
        }
        // approved_at first: it is the gate signal.
        for key in ["approved_at", "approved_by"] {
            do {
                _ = try await services.tools.call(
                    server: "work42-session", tool: "storage_delete",
                    arguments: ["key": .string("plan/\(key)")], session: nil)
            } catch {
                errorMessage = "Couldn't clear plan/\(key): \(error.localizedDescription)"
                return
            }
        }
        isApproved = false
        approvers.remove(who.id)
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
            if let first = widget.tabs.first {
                BrowserSurface(
                    spec: BrowserSurfaceSpec(
                        url: first.url,
                        selector: "",
                        dataStoreKey: "browser",
                        title: "Spec Document",
                        icon: "doc.text"
                    ),
                    cacheKey: widget.id,
                    configure: { [weak widget] model in
                        guard let widget else { return }
                        widget.browserModel = model
                        widget.syncTabs()
                        // Documents come from the issues' storage, so + has nothing to add.
                        model.onNewTab = {}
                        model.onTabClosed = { [weak widget] tabID in widget?.tabClosed(tabID) }
                    }
                )
                .onChange(of: widget.tabs.map(\.slugID)) { _, _ in widget.syncTabs() }
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
