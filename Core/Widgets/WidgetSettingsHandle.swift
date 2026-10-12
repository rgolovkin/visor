import Foundation

/// Gives a widget typed access to its own `widgets[i].settings` object in config.json.
@MainActor
final class WidgetSettingsHandle {
    let widgetID: String
    private let store: ConfigStore

    init(widgetID: String, store: ConfigStore) {
        self.widgetID = widgetID
        self.store = store
    }

    /// `nil` means "use your defaults" (missing entry or undecodable settings).
    func load<S: Decodable>(_ type: S.Type) -> S? {
        guard let entry = store.document.widgets.first(where: { $0.id == widgetID }) else { return nil }
        do {
            return try entry.settings.decode(type)
        } catch {
            Log.widgets.error("Cannot decode settings of \(self.widgetID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Merges into the existing object so keys this version does not know about survive.
    func save<S: Encodable>(_ value: S) {
        let encoded: [String: JSONValue]
        do {
            guard let object = try JSONValue.encode(value).objectValue else {
                Log.widgets.error("Settings of \(self.widgetID, privacy: .public) must encode to a JSON object")
                return
            }
            encoded = object
        } catch {
            Log.widgets.error("Cannot encode settings of \(self.widgetID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let id = widgetID
        store.update { document in
            guard let index = document.widgets.firstIndex(where: { $0.id == id }) else {
                Log.widgets.error("No config entry for widget \(id, privacy: .public)")
                return
            }
            document.widgets[index].settings = document.widgets[index].settings.merging(encoded)
        }
    }
}
