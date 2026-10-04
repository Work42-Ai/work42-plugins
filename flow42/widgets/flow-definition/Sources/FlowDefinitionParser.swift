import Foundation

indirect enum YAMLValue: Equatable {
    case scalar(String)
    case object([String: YAMLValue])
    case array([YAMLValue])

    var string: String? { if case .scalar(let value) = self { value } else { nil } }
    var object: [String: YAMLValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [YAMLValue]? { if case .array(let value) = self { value } else { nil } }
}

struct SimpleYAMLParser {
    private struct Line { let indent: Int; let text: String }
    private var lines: [Line]
    private var index = 0

    init(_ source: String) {
        lines = source.split(whereSeparator: \ .isNewline).compactMap { raw in
            let text = String(raw)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return Line(indent: text.prefix(while: { $0 == " " }).count, text: trimmed)
        }
    }

    mutating func parse() -> YAMLValue {
        guard let first = lines.first else { return .object([:]) }
        return parseBlock(indent: first.indent)
    }

    private mutating func parseBlock(indent: Int) -> YAMLValue {
        guard index < lines.count else { return .object([:]) }
        return lines[index].text.hasPrefix("- ")
            ? .array(parseArray(indent: indent))
            : .object(parseObject(indent: indent))
    }

    private mutating func parseObject(indent: Int) -> [String: YAMLValue] {
        var result: [String: YAMLValue] = [:]
        while index < lines.count, lines[index].indent == indent, !lines[index].text.hasPrefix("- ") {
            let current = lines[index].text
            index += 1
            guard let colon = current.firstIndex(of: ":") else { continue }
            let key = String(current[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(current[current.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                result[key] = .scalar(unquote(rest))
            } else if index < lines.count, lines[index].indent > indent {
                result[key] = parseBlock(indent: lines[index].indent)
            } else {
                result[key] = .object([:])
            }
        }
        return result
    }

    private mutating func parseArray(indent: Int) -> [YAMLValue] {
        var result: [YAMLValue] = []
        while index < lines.count, lines[index].indent == indent, lines[index].text.hasPrefix("- ") {
            let payload = String(lines[index].text.dropFirst(2))
            index += 1
            if payload.isEmpty {
                result.append(index < lines.count ? parseBlock(indent: lines[index].indent) : .object([:]))
                continue
            }
            guard let colon = payload.firstIndex(of: ":") else {
                result.append(.scalar(unquote(payload)))
                continue
            }
            var object: [String: YAMLValue] = [:]
            let key = String(payload[..<colon]).trimmingCharacters(in: .whitespaces)
            let rest = String(payload[payload.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                object[key] = .scalar(unquote(rest))
            } else if index < lines.count, lines[index].indent > indent + 2 {
                object[key] = parseBlock(indent: lines[index].indent)
            } else {
                object[key] = .object([:])
            }
            if index < lines.count, lines[index].indent == indent + 2, !lines[index].text.hasPrefix("- ") {
                object.merge(parseObject(indent: indent + 2), uniquingKeysWith: { _, new in new })
            }
            result.append(.object(object))
        }
        return result
    }

    private func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

struct FlowDefinitionLoader {
    let registryRoot: URL

    init(registryRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".work42/flows", isDirectory: true)) {
        self.registryRoot = registryRoot
    }

    func load(_ selection: FlowSelection) throws -> FlowDefinition {
        let family = registryRoot.appendingPathComponent(selection.flow, isDirectory: true)
        let manifestURL = family.appendingPathComponent("manifest.yaml")
        let manifestRoot = try parseFile(manifestURL)
        guard let map = manifestRoot.object else {
            throw FlowDefinitionError.invalidManifest("manifest.yaml must contain a mapping.")
        }
        let id = map["id"]?.string ?? ""
        guard id == selection.flow else {
            throw FlowDefinitionError.invalidManifest("Manifest id must match the flow directory.")
        }
        guard let variants = map["variants"]?.object,
              let relative = variants[selection.variant]?.string else {
            throw FlowDefinitionError.invalidManifest("Variant '\(selection.variant)' is not declared by this flow.")
        }
        let familyPath = family.standardizedFileURL.resolvingSymlinksInPath().path
        let flowURL = family.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard !relative.hasPrefix("/"), flowURL.path.hasPrefix(familyPath + "/") else {
            throw FlowDefinitionError.unsafeVariantPath("Variant path escapes its flow family.")
        }
        let manifest = FlowManifest(
            id: id,
            name: map["name"]?.string ?? id,
            description: map["description"]?.string,
            tags: map["tags"]?.array?.compactMap(\.string) ?? [],
            variants: variants.compactMapValues(\.string)
        )
        return try buildDefinition(selection, manifest: manifest, url: flowURL)
    }

    private func buildDefinition(_ selection: FlowSelection, manifest: FlowManifest, url: URL) throws -> FlowDefinition {
        let root = try parseFile(url)
        guard let map = root.object else { throw FlowDefinitionError.unreadable("flow.yaml must contain a mapping.") }
        var warnings: [FlowWarning] = []
        let device = map["device"]?.string ?? ""
        if device.isEmpty { warnings.append(.init(field: "device", message: "Missing Work42 device compatibility class.")) }

        let parameters = (map["parameters"]?.object ?? [:]).map { key, value in
            let fields = value.object ?? [:]
            return FlowParameter(id: key, type: fields["type"]?.string, description: fields["description"]?.string)
        }.sorted { $0.id < $1.id }

        let variantDirectory = url.deletingLastPathComponent()
        let phaseNodes = map["phases"]?.array ?? []
        if phaseNodes.isEmpty { warnings.append(.init(field: "phases", message: "No phases are defined.")) }
        let phases = phaseNodes.enumerated().map { phaseIndex, node -> FlowPhase in
            let fields = node.object ?? [:]
            let phaseID = fields["id"]?.string ?? "phase-\(phaseIndex + 1)"
            if fields["id"]?.string == nil { warnings.append(.init(field: "phases[\(phaseIndex)].id", message: "Missing phase id.")) }
            let stepNodes = fields["steps"]?.array ?? []
            if stepNodes.isEmpty { warnings.append(.init(field: "phases[\(phaseIndex)].steps", message: "No steps are defined.")) }
            let steps = stepNodes.enumerated().map { stepIndex, stepNode -> FlowStep in
                let step = stepNode.object ?? [:]
                let path = "phases[\(phaseIndex)].steps[\(stepIndex)]"
                let action = step["action"]?.string
                if action == nil { warnings.append(.init(field: path + ".action", message: "Missing Work42 action.")) }
                if step["precondition"]?.string == nil { warnings.append(.init(field: path + ".precondition", message: "Missing precondition.")) }
                if step["postcondition"]?.string == nil { warnings.append(.init(field: path + ".postcondition", message: "Missing postcondition.")) }
                let args = flatten(step["arguments"]?.object ?? [:])
                var screenshotURL: URL?
                if let screenshot = step["screenshot"]?.string {
                    let candidate = variantDirectory.appendingPathComponent(screenshot).standardizedFileURL
                    if screenshot.hasPrefix("/") || !candidate.path.hasPrefix(variantDirectory.standardizedFileURL.path + "/") {
                        warnings.append(.init(field: path + ".screenshot", message: "Screenshot path escapes the variant directory."))
                    } else if !FileManager.default.fileExists(atPath: candidate.path) {
                        warnings.append(.init(field: path + ".screenshot", message: "Screenshot file is missing."))
                    } else { screenshotURL = candidate }
                }
                return FlowStep(id: "\(phaseID)-\(stepIndex + 1)", action: action, arguments: args,
                    precondition: step["precondition"]?.string, postcondition: step["postcondition"]?.string,
                    screenshot: screenshotURL)
            }
            return FlowPhase(id: phaseID, intent: fields["intent"]?.string, steps: steps)
        }
        return FlowDefinition(selection: selection, manifest: manifest, device: device,
            parameters: parameters, phases: phases, warnings: warnings, directory: variantDirectory)
    }

    private func parseFile(_ url: URL) throws -> YAMLValue {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw FlowDefinitionError.unreadable("Could not read \(url.lastPathComponent).")
        }
        var parser = SimpleYAMLParser(source)
        return parser.parse()
    }

    private func flatten(_ object: [String: YAMLValue], prefix: String = "") -> [(String, String)] {
        object.keys.sorted().flatMap { key -> [(String, String)] in
            let field = prefix.isEmpty ? key : "\(prefix).\(key)"
            guard let value = object[key] else { return [] }
            if let scalar = value.string { return [(field, scalar)] }
            if let nested = value.object { return flatten(nested, prefix: field) }
            return [(field, value.array?.compactMap(\.string).joined(separator: ", ") ?? "")]
        }
    }
}
