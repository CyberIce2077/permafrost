import AppIntents
import WidgetKit

/// Right-click › Edit Widget. Each widget on the desktop can pick its own servers and stats;
/// anything left empty follows Ice Servers › Settings › Widgets.
struct ConfigureWidget: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Servers"
    static let description = IntentDescription("Choose what this widget shows. Empty choices follow Ice Servers › Settings › Widgets.")

    @Parameter(title: "Name")
    var name: String?

    @Parameter(title: "Servers", size: 4)
    var servers: [ServerEntity]?

    @Parameter(title: "Stats")
    var stats: [StatOption]?

    @Parameter(title: "Style")
    var style: StyleOption?

    @Parameter(title: "Appearance")
    var look: LookOption?
}

struct ServerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Server"
    static let defaultQuery = ServerQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ServerQuery: EntityQuery {
    private var all: [ServerEntity] { (Store.load()?.servers ?? []).map { ServerEntity(id: $0.id, name: $0.name) } }

    func entities(for identifiers: [String]) async throws -> [ServerEntity] {
        all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ServerEntity] { all }
}

enum StatOption: String, AppEnum {
    case cpu, mem, net, disk, temp

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Stat"
    static let caseDisplayRepresentations: [StatOption: DisplayRepresentation] = [
        .cpu: "CPU", .mem: "Memory", .net: "Network", .disk: "Disk", .temp: "Temperature",
    ]
}

enum StyleOption: String, AppEnum {
    case bars, rings, graph

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [StyleOption: DisplayRepresentation] = [
        .bars: "Bars", .rings: "Rings", .graph: "Graphs",
    ]
}

enum LookOption: String, AppEnum {
    case glass, tinted, clear

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Appearance"
    static let caseDisplayRepresentations: [LookOption: DisplayRepresentation] = [
        .glass: "Glass", .tinted: "Tinted", .clear: "Clear",
    ]
}
