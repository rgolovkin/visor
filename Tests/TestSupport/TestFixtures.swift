import Foundation
@testable import NotchApp

enum TestFixtures {
    static let defaultOrder = ["clock", "calendar", "timer", "battery", "weather", "sysmon", "notes"]

    static func jsonObject(at url: URL) throws -> [String: JSONValue] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(JSONValue.self, from: data).objectValue ?? [:]
    }

    static func files(in directory: URL, prefix: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }
}

@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
