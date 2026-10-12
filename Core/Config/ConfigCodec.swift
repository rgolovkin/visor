import Foundation

enum ConfigCodecError: Error, Equatable {
    case rootIsNotObject
}

/// Tolerant decoding: only invalid JSON or a non-object root throws; a malformed field falls back
/// to its default. Unknown keys at every level are kept in `extra` and written back (ADR-002).
enum ConfigCodec {
    static let currentSchemaVersion = 1

    private enum Key {
        static let schemaVersion = "schemaVersion"
        static let general = "general"
        static let widgets = "widgets"
        static let launchAtLogin = "launchAtLogin"
        static let displayMode = "displayMode"
        static let displayId = "displayId"
        static let displayName = "displayName"
        static let id = "id"
        static let enabled = "enabled"
        static let settings = "settings"
    }

    static func decode(_ data: Data) throws -> ConfigDocument {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard var object = root.objectValue else { throw ConfigCodecError.rootIsNotObject }

        let schemaVersion = object.removeValue(forKey: Key.schemaVersion)?.intValue ?? currentSchemaVersion
        let general = decodeGeneral(object.removeValue(forKey: Key.general))
        let widgets = decodeWidgets(object.removeValue(forKey: Key.widgets))
        return ConfigDocument(schemaVersion: schemaVersion, general: general, widgets: widgets, extra: object)
    }

    static func encode(_ document: ConfigDocument) throws -> Data {
        var root = document.extra
        root[Key.schemaVersion] = .integer(Int64(document.schemaVersion))
        root[Key.general] = encodeGeneral(document.general)
        root[Key.widgets] = .array(document.widgets.map(encodeWidget))
        return try JSONValue.makeEncoder().encode(JSONValue.object(root))
    }

    private static func decodeGeneral(_ value: JSONValue?) -> GeneralConfig {
        var general = GeneralConfig()
        guard var object = value?.objectValue else { return general }

        if let flag = object.removeValue(forKey: Key.launchAtLogin)?.boolValue {
            general.launchAtLogin = flag
        }
        if let raw = object.removeValue(forKey: Key.displayMode)?.stringValue {
            if let mode = DisplayMode(rawValue: raw) {
                general.displayMode = mode
            } else {
                Log.config.warning("Unknown displayMode in config, falling back to auto")
            }
        }
        general.displayId = object.removeValue(forKey: Key.displayId)?.stringValue
        general.displayName = object.removeValue(forKey: Key.displayName)?.stringValue
        general.extra = object
        return general
    }

    private static func encodeGeneral(_ general: GeneralConfig) -> JSONValue {
        var object = general.extra
        object[Key.launchAtLogin] = .bool(general.launchAtLogin)
        object[Key.displayMode] = .string(general.displayMode.rawValue)
        object[Key.displayId] = general.displayId.map(JSONValue.string) ?? .null
        if let name = general.displayName {
            object[Key.displayName] = .string(name)
        }
        return .object(object)
    }

    private static func decodeWidgets(_ value: JSONValue?) -> [WidgetConfigEntry] {
        guard let array = value?.arrayValue else { return [] }
        var seen = Set<String>()
        var entries: [WidgetConfigEntry] = []
        for element in array {
            guard var object = element.objectValue,
                  let id = object.removeValue(forKey: Key.id)?.stringValue, !id.isEmpty else {
                Log.config.warning("Skipping widget entry without a valid id")
                continue
            }
            guard seen.insert(id).inserted else {
                Log.config.warning("Skipping duplicate widget entry \(id, privacy: .public)")
                continue
            }
            let enabled = object.removeValue(forKey: Key.enabled)?.boolValue ?? true
            let settings = object.removeValue(forKey: Key.settings)?.objectValue ?? [:]
            entries.append(WidgetConfigEntry(id: id, enabled: enabled, settings: .object(settings), extra: object))
        }
        return entries
    }

    private static func encodeWidget(_ entry: WidgetConfigEntry) -> JSONValue {
        var object = entry.extra
        object[Key.id] = .string(entry.id)
        object[Key.enabled] = .bool(entry.enabled)
        object[Key.settings] = entry.settings.objectValue != nil ? entry.settings : .object([:])
        return .object(object)
    }
}
