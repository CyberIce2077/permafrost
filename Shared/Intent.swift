import AppIntents
import WidgetKit

/// Right-click › Edit Widget: which design from Settings › Widgets this widget shows.
/// Until one is picked, the widget asks for it.
/// Also built into the app, which reads it to count the widgets using each design.
struct ConfigureWidget: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Ice Servers"
    static let description = IntentDescription("Pick a design. Make and change designs in Ice Servers › Settings › Widgets.")

    @Parameter(title: "Design")
    var design: DesignEntity?

    init() {}
}

struct DesignEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Design"
    static let defaultQuery = DesignQuery()

    var id: String
    var name: String
    var detail: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(detail)") }

    init(_ d: Design, _ config: Config) {
        id = d.id
        name = d.name
        let size = ["S": "Small", "M": "Medium", "L": "Large", "XL": "Extra Large"][d.size] ?? ""
        let shown = d.servers(in: config)
        detail = size + " · " + (d.all ? "All servers" : shown.count == 1 ? shown[0].name : "\(shown.count) servers")
    }
}

struct DesignQuery: EntityQuery {
    private var all: [DesignEntity] {
        let config = Store.load() ?? Config()
        return (config.designs ?? []).map { DesignEntity($0, config) }
    }

    func entities(for identifiers: [String]) async throws -> [DesignEntity] { all.filter { identifiers.contains($0.id) } }
    // No defaultResult: a new widget starts without a design and asks for one.
    func suggestedEntities() async throws -> [DesignEntity] { all }
}
