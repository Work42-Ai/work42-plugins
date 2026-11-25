import Foundation
import Observation

struct FlowSelection: Equatable, Sendable {
    let flow: String
    let variant: String

    static func parse(_ url: URL) throws -> FlowSelection {
        guard url.scheme?.lowercased() == "flow42", url.host?.lowercased() == "flow" else {
            throw FlowDefinitionError.invalidLink("Expected flow42://flow/<flow>?variant=<variant>.")
        }
        let flow = url.pathComponents.dropFirst().first ?? ""
        let variant = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "variant" })?.value ?? ""
        guard isSlug(flow), isSlug(variant) else {
            throw FlowDefinitionError.invalidLink("Both flow and variant must be explicit lowercase slugs.")
        }
        return FlowSelection(flow: flow, variant: variant)
    }

    static func isSlug(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }
}

struct FlowManifest: Equatable, Sendable {
    let id: String
    let name: String
    let description: String?
    let tags: [String]
    let variants: [String: String]

    var orderedVariantIDs: [String] {
        let preferred = ["browser", "ios", "android"]
        return preferred.filter(variants.keys.contains) +
            variants.keys.filter { !preferred.contains($0) }.sorted()
    }
}

struct FlowCatalogItem: Equatable, Sendable, Identifiable {
    let id: String
    let manifest: FlowManifest?
    let orderedVariants: [String]
    let preview: FlowDefinition?
    let warning: FlowWarning?

    var name: String { manifest?.name ?? id }
    var variantCount: Int { orderedVariants.count }
    var previewStepCount: Int {
        preview?.phases.reduce(0) { $0 + $1.steps.count } ?? 0
    }

    static func valid(manifest: FlowManifest, preview: FlowDefinition) -> FlowCatalogItem {
        FlowCatalogItem(
            id: manifest.id,
            manifest: manifest,
            orderedVariants: manifest.orderedVariantIDs,
            preview: preview,
            warning: nil
        )
    }

    static func invalid(id: String, manifest: FlowManifest? = nil, message: String) -> FlowCatalogItem {
        FlowCatalogItem(
            id: id,
            manifest: manifest,
            orderedVariants: manifest?.orderedVariantIDs ?? [],
            preview: nil,
            warning: FlowWarning(field: "catalog", message: message)
        )
    }
}

struct FlowVariantTab: Hashable, Identifiable, Sendable {
    let id: String
    var label: String { id.replacingOccurrences(of: "-", with: " ").capitalized }
}

struct FlowDetailState: Equatable, Sendable {
    let flowID: String
    let name: String
    let variants: [String]
    var selectedVariant: String
    var definition: FlowDefinition?
    var errorMessage: String?

    var variantTabs: [FlowVariantTab] { variants.map(FlowVariantTab.init(id:)) }
}

@Observable
@MainActor
final class FlowDefinitionNavigation {
    enum Page: Equatable, Sendable {
        case library
        case detail(FlowDetailState)
    }

    private(set) var catalog: [FlowCatalogItem] = []
    private(set) var page: Page = .library
    private let loader: FlowDefinitionLoader

    init(loader: FlowDefinitionLoader = FlowDefinitionLoader()) {
        self.loader = loader
    }

    func reloadCatalog() {
        catalog = loader.list()
    }

    func select(_ item: FlowCatalogItem) {
        guard item.warning == nil, let firstVariant = item.orderedVariants.first else { return }
        open(.init(flow: item.id, variant: firstVariant))
    }

    func open(_ selection: FlowSelection) {
        if catalog.isEmpty { reloadCatalog() }
        let item = catalog.first { $0.id == selection.flow }
        let variants = item?.orderedVariants.isEmpty == false
            ? item!.orderedVariants
            : [selection.variant]
        var detail = FlowDetailState(
            flowID: selection.flow,
            name: item?.name ?? selection.flow,
            variants: variants,
            selectedVariant: selection.variant,
            definition: nil,
            errorMessage: nil
        )
        do {
            detail.definition = try loader.load(selection)
        } catch {
            detail.errorMessage = Self.actionable(error.localizedDescription)
        }
        page = .detail(detail)
    }

    func selectVariant(_ variant: String) {
        guard case .detail(let current) = page,
              current.variants.contains(variant) else { return }
        open(.init(flow: current.flowID, variant: variant))
    }

    func back() {
        reloadCatalog()
        page = .library
    }

    func showLinkError(_ message: String) {
        page = .detail(FlowDetailState(
            flowID: "",
            name: "Flow unavailable",
            variants: [],
            selectedVariant: "",
            definition: nil,
            errorMessage: Self.actionable(message)
        ))
    }

    private static func actionable(_ message: String) -> String {
        "\(message) Choose another available variant or return to Flows."
    }
}

struct FlowDefinition: Equatable, Sendable {
    let selection: FlowSelection
    let manifest: FlowManifest
    let device: String
    let parameters: [FlowParameter]
    let phases: [FlowPhase]
    let warnings: [FlowWarning]
    let directory: URL

    var commentKey: String {
        "flow42/flows/\(selection.flow)/\(selection.variant)"
    }
}

struct FlowParameter: Equatable, Sendable, Identifiable {
    let id: String
    let type: String?
    let description: String?
}

struct FlowPhase: Equatable, Sendable, Identifiable {
    let id: String
    let intent: String?
    let steps: [FlowStep]
}

struct FlowStep: Equatable, Sendable, Identifiable {
    let id: String
    let action: String?
    let arguments: [(String, String)]
    let precondition: String?
    let postcondition: String?
    let screenshot: URL?

    static func == (lhs: FlowStep, rhs: FlowStep) -> Bool {
        lhs.id == rhs.id && lhs.action == rhs.action &&
        lhs.arguments.elementsEqual(rhs.arguments, by: ==) &&
        lhs.precondition == rhs.precondition && lhs.postcondition == rhs.postcondition &&
        lhs.screenshot == rhs.screenshot
    }
}

struct FlowWarning: Equatable, Sendable, Identifiable {
    let field: String
    let message: String
    var id: String { "\(field):\(message)" }
}

enum FlowDefinitionError: LocalizedError, Equatable {
    case invalidLink(String)
    case invalidManifest(String)
    case unsafeVariantPath(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .invalidLink(let message), .invalidManifest(let message),
             .unsafeVariantPath(let message), .unreadable(let message): message
        }
    }
}
