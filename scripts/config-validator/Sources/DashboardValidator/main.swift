import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

func readYAML() -> (label: String, yaml: String)? {
    guard let path = arguments.first, path != "-" else {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let yaml = String(data: data, encoding: .utf8) else { return nil }
        return ("<stdin>", yaml)
    }
    guard let yaml = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    return (path, yaml)
}

guard arguments.count <= 1, !arguments.contains(where: { $0 == "-h" || $0 == "--help" }) else {
    print("usage: DashboardValidator [dashboard.yaml | -]")
    exit(2)
}

guard let (label, yaml) = readYAML() else {
    FileHandle.standardError.write(Data("error: could not read UTF-8 YAML input\n".utf8))
    exit(2)
}

do {
    let configuration = try AppConfigurationParser.parse(yaml)
    let cards = configuration.pages.flatMap(\.sections).flatMap(\.cards)
    let unsupported = cards.filter {
        if case .unsupported = $0 { return true }
        return false
    }

    print("OK \(label)")
    print("  version: \(configuration.version)")
    for page in configuration.pages {
        let pageCards = page.sections.flatMap(\.cards)
        print("  page \(page.id) — \"\(page.title)\" (\(page.systemIcon)), "
            + "\(page.sections.count) section(s), \(pageCards.count) card(s)")
        for card in pageCards {
            print("    - \(card.typeName)")
        }
    }

    // Unsupported cards render a placeholder rather than failing the load, so
    // they are worth calling out here — usually they are a typo'd type.
    for card in unsupported {
        print("  warning: unsupported card type \"\(card.typeName)\" renders as a placeholder")
    }
    exit(0)
} catch {
    FileHandle.standardError.write(Data("INVALID \(label)\n  \(error.localizedDescription)\n".utf8))
    exit(1)
}
