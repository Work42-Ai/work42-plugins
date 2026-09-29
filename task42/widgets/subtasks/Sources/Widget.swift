// Widget.swift — task42's Subtasks widget (task42-plugin-conversion, c6).
//
// Renders `plan/subtasks` (the task's implementation breakdown) as
// toggleable rows: check to flip `done`, tap a row to expand/collapse its
// description, trash to delete (behind a confirmation dialog). Mirrors
// SessionDetailPanel's subtasksSection/subtaskRow and the
// toggleSubtaskDone/deleteSubtask writers, through
// `services.storage.set(key: "subtasks", ...)` instead of the app-internal
// SessionService.setStorage path.
//
// The UI does not add subtasks — the planner writes `plan/subtasks`.
//
// STORAGE (storageNamespace "plan" — shared with the spec/testing-plan
// widgets and the workflow gates):
//   plan/subtasks — a JSON array of {id, title, description, done}.

import Observation
import SwiftUI
import Work42WidgetKit

/// A generic subtask row — mirrors SessionDetailPanel.PlanSubtask exactly
/// (same fields, same tolerant decode of absent description/done on older
/// rows) so `plan/subtasks` round-trips identically through either surface.
struct PluginSubtask: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var description: String
    var done: Bool

    private enum CodingKeys: String, CodingKey { case id, title, description, done }

    init(id: String, title: String, description: String, done: Bool) {
        self.id = id; self.title = title; self.description = description; self.done = done
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
    }
}

@Observable
@MainActor
final class SubtasksWidget: Work42Widget {

    // MARK: - Work42Widget conformance

    let id = "subtasks"
    let title = "Subtasks"
    let icon = "checklist"
    var storageNamespace: String? { "plan" }
    var linkIntents: [WidgetLinkIntentSpec] { [] }

    // MARK: - Observed state

    var subtasks: [PluginSubtask] = []
    var deletingSubtask = false
    var deleteSubtaskError: String?

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
        AnyView(SubtasksWidgetView(widget: self))
    }

    // MARK: - Storage

    func load() async {
        guard let services else { return }
        let value = (try? await services.storage.get(namespace: "plan", key: "subtasks")) ?? nil
        subtasks = Self.decode(value)
    }

    func toggleDone(_ sub: PluginSubtask) async {
        guard let idx = subtasks.firstIndex(where: { $0.id == sub.id }) else { return }
        subtasks[idx].done.toggle()
        await write()
    }

    func delete(_ sub: PluginSubtask) async {
        guard !deletingSubtask else { return }
        deletingSubtask = true
        deleteSubtaskError = nil
        defer { deletingSubtask = false }
        subtasks.removeAll { $0.id == sub.id }
        await write()
    }

    private func write() async {
        guard let services, let encoded = Self.encode(subtasks) else { return }
        do {
            try await services.storage.set(key: "subtasks", value: encoded)
        } catch {
            deleteSubtaskError = "Failed to write plan/subtasks: \(error.localizedDescription)"
        }
    }

    private static func decode(_ value: WidgetJSONValue?) -> [PluginSubtask] {
        guard let value, let data = try? JSONEncoder().encode(value) else { return [] }
        return (try? JSONDecoder().decode([PluginSubtask].self, from: data)) ?? []
    }

    private static func encode(_ rows: [PluginSubtask]) -> WidgetJSONValue? {
        guard let data = try? JSONEncoder().encode(rows) else { return nil }
        return try? JSONDecoder().decode(WidgetJSONValue.self, from: data)
    }
}

// MARK: - SubtasksWidgetView

private struct SubtasksWidgetView: View {
    let widget: SubtasksWidget

    @State private var expandedIDs: Set<String> = []
    @State private var pendingDelete: PluginSubtask?

    var body: some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            if widget.subtasks.isEmpty {
                Text("No subtasks yet.")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(widget.subtasks) { sub in
                        row(sub)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }

            if let error = widget.deleteSubtaskError {
                Text(error)
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.red)
            }
        }
        .padding(DT.s16)
        .task { await widget.load() }
        .confirmationDialog(
            pendingDelete.map { "Delete subtask \u{201c}\($0.title)\u{201d}?" } ?? "Delete subtask?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { sub in
            Button("Delete", role: .destructive) {
                Task { await widget.delete(sub) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Removes only this subtask row from the plan. The session, worktree, and remaining subtasks are not affected.")
        }
    }

    private func row(_ sub: PluginSubtask) -> some View {
        let isExpanded = expandedIDs.contains(sub.id)
        let trimmedDescription = sub.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 0) {
            HStack(spacing: DT.s8) {
                Button {
                    Task { await widget.toggleDone(sub) }
                } label: {
                    Image(systemName: sub.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(sub.done ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(sub.done ? "Mark not done" : "Mark done")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(sub.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(sub.title)
                    .font(.system(size: DT.f12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    widget.deleteSubtaskError = nil
                    pendingDelete = sub
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: DT.f11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(widget.deletingSubtask)
                .help("Delete this subtask")
            }
            .padding(.horizontal, DT.s12)
            .padding(.vertical, DT.s8)
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded {
                    expandedIDs.remove(sub.id)
                } else {
                    expandedIDs.insert(sub.id)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: DT.s4) {
                    if trimmedDescription.isEmpty {
                        Text("No description.")
                            .font(.system(size: DT.f11))
                            .foregroundStyle(.tertiary)
                            .italic()
                    } else {
                        Text(trimmedDescription)
                            .font(.system(size: DT.f11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DT.s12)
                .padding(.bottom, DT.s8)
            }

            Divider().opacity(0.25)
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
        result = WidgetEntryPoint.register(SubtasksWidget())
    }
    return result
}
