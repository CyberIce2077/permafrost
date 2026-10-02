import AppIntents
import WidgetKit

// Right-click › Edit Widget: which design from Settings › Widgets a widget shows. There's one widget
// per size, so each lists only the designs made for that size. The choice is the design's id as plain
// text (with its name shown in the list), not an AppEntity: macOS never resolved the entity back for
// the widget, so every widget saw "no design". Also built into the app, which counts the widgets
// using each design.

protocol DesignPicking: WidgetConfigurationIntent {
    var design: String? { get }
}

/// The designs of one size, for Edit Widget's list.
private func designItems(_ size: String) -> IntentItemCollection<String> {
    let config = Store.load() ?? Config()
    let items = (config.designs ?? []).filter { $0.size == size }.map { d -> IntentItem<String> in
        let shown = d.servers(in: config)
        let who = d.all ? "All servers" : shown.count == 1 ? shown[0].name : "\(shown.count) servers"
        return IntentItem(d.id, title: "\(d.name)", subtitle: "\(who)")
    }
    return IntentItemCollection { IntentItemSection(items: items) }
}

struct SmallDesigns: DynamicOptionsProvider {
    func results() async throws -> IntentItemCollection<String> { designItems("S") }
}

struct MediumDesigns: DynamicOptionsProvider {
    func results() async throws -> IntentItemCollection<String> { designItems("M") }
}

struct LargeDesigns: DynamicOptionsProvider {
    func results() async throws -> IntentItemCollection<String> { designItems("L") }
}

struct ExtraLargeDesigns: DynamicOptionsProvider {
    func results() async throws -> IntentItemCollection<String> { designItems("XL") }
}

struct ConfigureSmall: DesignPicking {
    static let title: LocalizedStringResource = "Ice Servers"
    static let description = IntentDescription("Pick a Small design. Make designs in Ice Servers › Custom Widgets.")
    @Parameter(title: "Design", optionsProvider: SmallDesigns()) var design: String?
    init() {}
}

struct ConfigureMedium: DesignPicking {
    static let title: LocalizedStringResource = "Ice Servers"
    static let description = IntentDescription("Pick a Medium design. Make designs in Ice Servers › Custom Widgets.")
    @Parameter(title: "Design", optionsProvider: MediumDesigns()) var design: String?
    init() {}
}

struct ConfigureLarge: DesignPicking {
    static let title: LocalizedStringResource = "Ice Servers"
    static let description = IntentDescription("Pick a Large design. Make designs in Ice Servers › Custom Widgets.")
    @Parameter(title: "Design", optionsProvider: LargeDesigns()) var design: String?
    init() {}
}

struct ConfigureExtraLarge: DesignPicking {
    static let title: LocalizedStringResource = "Ice Servers"
    static let description = IntentDescription("Pick an Extra Large design. Make designs in Ice Servers › Custom Widgets.")
    @Parameter(title: "Design", optionsProvider: ExtraLargeDesigns()) var design: String?
    init() {}
}

/// The design id a desktop widget picked, from the app's side.
func pickedDesign(_ w: WidgetInfo) -> String? {
    switch w.kind {
    case "IceServersS": w.widgetConfigurationIntent(of: ConfigureSmall.self)?.design
    case "IceServersM": w.widgetConfigurationIntent(of: ConfigureMedium.self)?.design
    case "IceServersL": w.widgetConfigurationIntent(of: ConfigureLarge.self)?.design
    case "IceServersXL": w.widgetConfigurationIntent(of: ConfigureExtraLarge.self)?.design
    default: nil
    }
}
