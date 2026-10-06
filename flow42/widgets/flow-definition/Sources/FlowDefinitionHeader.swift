import SwiftUI
import Work42UI
import Work42PluginKit

struct FlowDefinitionHeader: View {
    @Bindable var navigation: FlowDefinitionNavigation

    var body: some View {
        HStack(spacing: DT.s8) {
            switch navigation.page {
            case .library:
                Text("Flows")
                    .font(.system(size: DT.f12, weight: .medium))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 0)

            case .detail(let detail):
                Button { navigation.back() } label: {
                    Image(systemName: "chevron.left")
                }
                .glassIconButton()
                .help("Back to Flows")
                .accessibilityLabel("Back to Flows")

                Text(detail.name)
                    .font(.system(size: DT.f12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if detail.variantTabs.count > 1,
                   let selected = detail.variantTabs.first(where: { $0.id == detail.selectedVariant }) {
                    GlassTabStrip(
                        items: detail.variantTabs,
                        selection: Binding(
                            get: { selected },
                            set: { navigation.selectVariant($0.id) }
                        ),
                        label: { $0.label },
                        namespaceId: "flow-definition-variant"
                    )
                    .accessibilityLabel("Flow variant")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
