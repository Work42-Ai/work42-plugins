import SwiftUI
import Work42UI
import Work42PluginKit

struct FlowDefinitionHeader: View {
    @Bindable var navigation: FlowDefinitionNavigation

    var body: some View {
        HStack(spacing: DT.s8) {
            switch navigation.page {
            case .library:
                WidgetHeaderTitle(name: "Flows")
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 0)

            case .detail(let detail):
                HeaderRoundButton(systemImage: "chevron.left", label: "Back to Flows") { navigation.back() }

                WidgetHeaderTitle(name: detail.name)

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
