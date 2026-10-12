import Foundation

enum ConfigDefaults {
    static func document(catalogOrder: [String]) -> ConfigDocument {
        ConfigDocument(
            schemaVersion: ConfigCodec.currentSchemaVersion,
            general: GeneralConfig(),
            widgets: catalogOrder.map { WidgetConfigEntry(id: $0, enabled: true) }
        )
    }
}
