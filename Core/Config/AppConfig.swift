import Foundation

enum DisplayMode: String, Codable, Sendable, CaseIterable {
    case auto, primary, notch, display
}

struct GeneralConfig: Sendable, Equatable {
    var launchAtLogin: Bool = false
    var displayMode: DisplayMode = .auto
    var displayId: String?
    /// Additive field (ADR-002): only used to label a disconnected display in settings.
    var displayName: String?
    var extra: [String: JSONValue] = [:]
}

struct WidgetConfigEntry: Sendable, Equatable {
    var id: String
    var enabled: Bool
    /// Always a JSON object; its schema belongs to the widget.
    var settings: JSONValue = .object([:])
    var extra: [String: JSONValue] = [:]
}

struct ConfigDocument: Sendable, Equatable {
    var schemaVersion: Int
    var general: GeneralConfig
    var widgets: [WidgetConfigEntry]
    /// Unknown top-level keys, preserved verbatim on save.
    var extra: [String: JSONValue] = [:]
}

enum ConfigLoadIssue: Sendable, Equatable {
    case createdDefault
    case recoveredBroken(URL)
    case newerSchema(Int)
    case unreadable
    case writeFailed
}
