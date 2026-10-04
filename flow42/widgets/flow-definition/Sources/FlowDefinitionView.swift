import AppKit
import SwiftUI
import Work42WidgetKit

struct FlowDefinitionView: View {
    let widget: FlowDefinitionWidget

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DT.s12) {
                if let definition = widget.definition {
                    header(definition)
                    if !definition.warnings.isEmpty { warnings(definition.warnings) }
                    if !definition.parameters.isEmpty { parameters(definition.parameters) }
                    ForEach(Array(definition.phases.enumerated()), id: \.element.id) { index, phase in
                        phaseView(phase, number: index + 1)
                    }
                } else if let message = widget.errorMessage {
                    emptyState(title: "Flow unavailable", detail: message, symbol: "exclamationmark.triangle")
                } else {
                    emptyState(
                        title: "Open a flow definition",
                        detail: "Use flow42://flow/<flow>?variant=<variant>. Both values are required.",
                        symbol: "point.topleft.down.to.point.bottomright.curvepath"
                    )
                }
            }
            .padding(DT.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ definition: FlowDefinition) -> some View {
        VStack(alignment: .leading, spacing: DT.s4) {
            Text(definition.manifest.name)
                .font(.system(size: DT.f17, weight: .bold))
            if let description = definition.manifest.description {
                Text(description).font(.system(size: DT.f12)).foregroundStyle(.secondary)
            }
            HStack(spacing: DT.s8) {
                badge(definition.selection.flow)
                badge(definition.selection.variant)
                badge(definition.device.isEmpty ? "device missing" : definition.device)
            }
        }
    }

    private func warnings(_ values: [FlowWarning]) -> some View {
        VStack(alignment: .leading, spacing: DT.s4) {
            Label("Definition warnings", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: DT.f12, weight: .semibold))
            ForEach(values) { warning in
                Text("\(warning.field): \(warning.message)")
                    .font(.system(size: DT.f10, design: .monospaced))
            }
        }
        .padding(DT.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: DT.rCard))
    }

    private func parameters(_ values: [FlowParameter]) -> some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            Text("Parameters").font(.system(size: DT.f13, weight: .semibold))
            ForEach(values) { parameter in
                HStack(alignment: .firstTextBaseline) {
                    Text(parameter.id).font(.system(size: DT.f11, weight: .medium, design: .monospaced))
                    if let type = parameter.type { Text(type).font(.system(size: DT.f10)).foregroundStyle(.secondary) }
                    Spacer()
                }
                if let description = parameter.description {
                    Text(description).font(.system(size: DT.f10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(DT.s8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: DT.rCard))
    }

    private func phaseView(_ phase: FlowPhase, number: Int) -> some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            Text("\(number). \(phase.id)").font(.system(size: DT.f14, weight: .bold))
            if let intent = phase.intent { Text(intent).font(.system(size: DT.f11)).foregroundStyle(.secondary) }
            ForEach(Array(phase.steps.enumerated()), id: \.element.id) { index, step in
                stepView(step, number: index + 1)
            }
        }
    }

    private func stepView(_ step: FlowStep, number: Int) -> some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            HStack {
                Text("Step \(number)").font(.system(size: DT.f10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(step.action ?? "Missing action")
                    .font(.system(size: DT.f11, weight: .semibold, design: .monospaced))
            }
            if !step.arguments.isEmpty {
                VStack(alignment: .leading, spacing: DT.s4) {
                    ForEach(step.arguments, id: \.0) { key, value in
                        Text("\(key): \(value)").font(.system(size: DT.f10, design: .monospaced))
                    }
                }
            }
            condition("Before", step.precondition)
            condition("Expected", step.postcondition)
            if let screenshot = step.screenshot, let image = NSImage(contentsOf: screenshot) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: DT.rButton))
                    .overlay(RoundedRectangle(cornerRadius: DT.rButton).stroke(.secondary.opacity(0.2)))
                Text("Visual guidance · state immediately before the action")
                    .font(.system(size: DT.f9)).foregroundStyle(.secondary)
            }
        }
        .padding(DT.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: DT.rCard))
    }

    private func condition(_ label: String, _ text: String?) -> some View {
        HStack(alignment: .top, spacing: DT.s8) {
            Text(label.uppercased()).font(.system(size: DT.f9, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(text ?? "Not specified").font(.system(size: DT.f10))
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: DT.f9, weight: .medium, design: .monospaced))
            .padding(.horizontal, DT.s8).padding(.vertical, DT.s4)
            .background(.secondary.opacity(0.12), in: Capsule())
    }

    private func emptyState(title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.secondary)
            Text(title).font(.system(size: DT.f14, weight: .semibold))
            Text(detail).font(.system(size: DT.f11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
