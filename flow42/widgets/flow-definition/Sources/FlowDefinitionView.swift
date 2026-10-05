import SwiftUI
import Work42WidgetKit

struct FlowDefinitionView: View {
    @Bindable var navigation: FlowDefinitionNavigation
    let services: SessionServices

    private let columns = [
        GridItem(.flexible(), spacing: DT.s12),
        GridItem(.flexible(), spacing: DT.s12),
    ]

    var body: some View {
        switch navigation.page {
        case .library:
            library
        case .detail(let detail):
            detailView(detail)
        }
    }

    @ViewBuilder
    private var library: some View {
        if navigation.catalog.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: DT.s12) {
                    ForEach(navigation.catalog) { item in
                        if item.warning != nil {
                            warningCard(item)
                        } else {
                            flowCard(item)
                        }
                    }
                }
                .padding(DT.s12)
            }
            .accessibilityLabel("Available flows")
        }
    }

    private func flowCard(_ item: FlowCatalogItem) -> some View {
        Button { navigation.select(item) } label: {
            VStack(alignment: .leading, spacing: 0) {
                cardHeader(item)
                Divider().opacity(0.25)
                if let preview = item.preview {
                    MarkdownPreview(
                        text: FlowDefinitionMarkdownRenderer.render(preview),
                        baseURL: preview.directory
                    )
                    .allowsHitTesting(false)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipped()
                    .accessibilityHidden(true)
                }
            }
            .background(DT.surface)
            .clipShape(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous))
            .overlay(cardBorder)
            .contentShape(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open \(item.name)")
        .accessibilityLabel("\(item.name), \(item.variantCount) variants, \(item.previewStepCount) steps")
        .accessibilityHint("Open flow guidance")
    }

    private func cardHeader(_ item: FlowCatalogItem) -> some View {
        HStack(spacing: DT.s8) {
            Image(systemName: "doc.text")
                .font(.system(size: DT.f12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DT.rButton))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: DT.f12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(item.variantCount) \(item.variantCount == 1 ? "variant" : "variants") · \(item.previewStepCount) steps")
                    .font(.system(size: DT.f9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: DT.f10, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, DT.s12)
        .frame(height: 50)
        .background(Color.primary.opacity(0.025))
    }

    private func warningCard(_ item: FlowCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: DT.s8) {
            Label(item.name, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: DT.f12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(item.warning?.message ?? "This flow could not be read.")
                .font(.system(size: DT.f10))
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Spacer(minLength: 0)
        }
        .padding(DT.s12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background(DT.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DT.rCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
                .strokeBorder(DT.orange.opacity(0.24), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name) unavailable")
    }

    @ViewBuilder
    private func detailView(_ detail: FlowDetailState) -> some View {
        if let definition = detail.definition {
            Work42MarkdownDocument(
                text: FlowDefinitionMarkdownRenderer.render(definition),
                sessionId: services.sessionId,
                commentKey: definition.commentKey,
                artifactsEnabled: false,
                baseURL: definition.directory
            )
            .accessibilityLabel("\(detail.name), \(detail.selectedVariant) guidance")
        } else {
            VStack(alignment: .leading, spacing: DT.s8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(DT.orange)
                Text("Variant unavailable")
                    .font(.system(size: DT.f14, weight: .semibold))
                Text(detail.errorMessage ?? "This flow variant could not be loaded.")
                    .font(.system(size: DT.f11))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(DT.s16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Variant unavailable")
        }
    }

    private var emptyState: some View {
        VStack(spacing: DT.s16) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No flows available")
                .font(.system(size: DT.f13, weight: .medium))
            Text("Create a flow in ~/.work42/flows and it will appear here.")
                .font(.system(size: DT.f11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(DT.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No flows available")
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: DT.rCard, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
    }
}
