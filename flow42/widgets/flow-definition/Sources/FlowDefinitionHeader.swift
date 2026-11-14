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

                if detail.variantTabs.count > 1 {
                    // The SDK's header tab strip: one control high, like every header control.
                    HeaderTabStrip(
                        detail.variantTabs.map { tab in
                            HeaderTab(id: tab.id, help: tab.label) {
                                Text(tab.label).font(.system(size: DT.f12, weight: .medium)).lineLimit(1)
                            }
                        },
                        selection: detail.selectedVariant,
                        onSelect: { navigation.selectVariant($0) }
                    )
                    .accessibilityLabel("Flow variant")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
