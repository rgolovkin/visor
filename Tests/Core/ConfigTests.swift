import Foundation
import Testing
@testable import NotchApp

@MainActor
struct ConfigTests {
    private func makeStore(_ dir: TempDirectory, delay: Duration = .milliseconds(30)) -> ConfigStore {
        ConfigStore(
            paths: AppPaths(root: dir.url),
            defaultWidgetOrder: TestFixtures.defaultOrder,
            saveDelay: delay
        )
    }

    private func write(_ json: String, to dir: TempDirectory) throws {
        try Data(json.utf8).write(to: AppPaths(root: dir.url).config)
    }

    // AC-13
    @Test func missingFileCreatesDefaults() throws {
        let dir = try TempDirectory()
        let store = makeStore(dir)
        store.load()

        #expect(store.loadIssue == .createdDefault)
        let json = try TestFixtures.jsonObject(at: AppPaths(root: dir.url).config)
        #expect(json["schemaVersion"] == .number(1))
        #expect(json["general"]?["displayMode"] == .string("auto"))
        #expect(json["general"]?["displayId"] == .null)
        #expect(json["general"]?["launchAtLogin"] == .bool(false))
        let ids = json["widgets"]?.arrayValue?.compactMap { $0["id"]?.stringValue }
        #expect(ids == TestFixtures.defaultOrder)
        let enabled = json["widgets"]?.arrayValue?.compactMap { $0["enabled"]?.boolValue }
        #expect(enabled == Array(repeating: true, count: 7))
    }

    // AC-14
    @Test(arguments: ["{not json", "[1,2,3]", ""])
    func brokenFileIsMovedAsideAndDefaultsCreated(_ contents: String) throws {
        let dir = try TempDirectory()
        try write(contents, to: dir)
        let store = makeStore(dir)
        store.load()

        guard case .recoveredBroken(let url) = store.loadIssue else {
            Issue.record("expected recoveredBroken, got \(String(describing: store.loadIssue))")
            return
        }
        #expect(url.lastPathComponent.hasPrefix("config.json.broken-"))
        #expect(try String(contentsOf: url, encoding: .utf8) == contents)
        #expect(store.document == ConfigDefaults.document(catalogOrder: TestFixtures.defaultOrder))
        #expect(FileManager.default.fileExists(atPath: AppPaths(root: dir.url).config.path))
    }

    // AC-15
    @Test func newerSchemaIsReadBackedUpOnceAndNotDowngraded() throws {
        let dir = try TempDirectory()
        try write("""
        {"schemaVersion": 2, "futureRoot": {"x": 1},
         "general": {"displayMode": "primary", "futureGeneral": "y"},
         "widgets": [{"id": "clock", "enabled": false, "settings": {"a": 1}, "futureEntry": true}]}
        """, to: dir)
        let store = makeStore(dir)
        store.load()

        #expect(store.loadIssue == .newerSchema(2))
        #expect(store.document.general.displayMode == .primary)
        #expect(store.document.widgets.first?.enabled == false)

        store.update { $0.general.launchAtLogin = true }
        store.flush()
        store.update { $0.general.launchAtLogin = false }
        store.flush()

        let backups = try TestFixtures.files(in: dir.url, prefix: "config.json.v2-backup-")
        #expect(backups.count == 1)
        let json = try TestFixtures.jsonObject(at: AppPaths(root: dir.url).config)
        #expect(json["schemaVersion"] == .number(2))
        #expect(json["futureRoot"] == .object(["x": .number(1)]))
        #expect(json["general"]?["futureGeneral"] == .string("y"))
        #expect(json["widgets"]?.arrayValue?.first?["futureEntry"] == .bool(true))
    }

    // AC-16
    @Test func unknownIDsAndKeysSurviveSave() throws {
        let dir = try TempDirectory()
        try write("""
        {"schemaVersion": 1, "rootExtra": [1, "two"],
         "general": {"displayMode": "auto", "displayId": null, "launchAtLogin": false, "gExtra": true},
         "widgets": [
           {"id": "clock", "enabled": true, "settings": {"format": "24h", "unknownSetting": 5}},
           {"id": "future-widget", "enabled": true, "settings": {"k": "v"}, "itemExtra": null}
         ]}
        """, to: dir)
        let store = makeStore(dir)
        store.load()
        #expect(store.loadIssue == nil)

        store.update { $0.widgets[0].enabled = false }
        store.flush()

        let json = try TestFixtures.jsonObject(at: AppPaths(root: dir.url).config)
        #expect(json["rootExtra"] == .array([.number(1), .string("two")]))
        #expect(json["general"]?["gExtra"] == .bool(true))
        let widgets = json["widgets"]?.arrayValue ?? []
        #expect(widgets.count == 2)
        #expect(widgets[0]["enabled"] == .bool(false))
        #expect(widgets[0]["settings"] == .object(["format": .string("24h"), "unknownSetting": .number(5)]))
        #expect(widgets[1]["id"] == .string("future-widget"))
        #expect(widgets[1]["settings"] == .object(["k": .string("v")]))
        #expect(widgets[1].objectValue?.keys.contains("itemExtra") == true)
    }

    @Test func tolerantDecodingFallsBackPerField() throws {
        let data = Data("""
        {"general": {"displayMode": "everywhere", "launchAtLogin": "yes"},
         "widgets": [{"id": "clock", "settings": 3}, {"enabled": true}, {"id": "clock", "enabled": false}]}
        """.utf8)
        let doc = try ConfigCodec.decode(data)
        #expect(doc.schemaVersion == 1)
        #expect(doc.general.displayMode == .auto)
        #expect(doc.general.launchAtLogin == false)
        #expect(doc.widgets == [WidgetConfigEntry(id: "clock", enabled: true)])
    }

    // AC-17
    @Test func updateIsDebouncedAndAtomicWriteHappens() async throws {
        let dir = try TempDirectory()
        let store = makeStore(dir, delay: .milliseconds(100))
        store.load()
        let configURL = AppPaths(root: dir.url).config

        store.update { $0.general.displayMode = .primary }
        let json = try TestFixtures.jsonObject(at: configURL)
        #expect(json["general"]?["displayMode"] == .string("auto"))

        await waitUntil {
            (try? TestFixtures.jsonObject(at: configURL))?["general"]?["displayMode"] == .string("primary")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(leftovers == ["config.json"])
    }

    @Test func flushWritesImmediately() throws {
        let dir = try TempDirectory()
        let store = makeStore(dir, delay: .seconds(10))
        store.load()
        store.update { $0.general.displayMode = .notch }
        store.flush()
        let json = try TestFixtures.jsonObject(at: AppPaths(root: dir.url).config)
        #expect(json["general"]?["displayMode"] == .string("notch"))
    }

    @Test func noOpUpdateDoesNotMarkDirty() throws {
        let dir = try TempDirectory()
        let store = makeStore(dir)
        store.load()
        let configURL = AppPaths(root: dir.url).config
        try FileManager.default.removeItem(at: configURL)
        store.update { $0.general.displayMode = .auto }
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: configURL.path))
    }

    @Test func readOnlyDirectoryKeepsWorkingInMemory() throws {
        let dir = try TempDirectory()
        let locked = dir.url.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        let store = ConfigStore(
            paths: AppPaths(root: locked),
            defaultWidgetOrder: TestFixtures.defaultOrder,
            saveDelay: .milliseconds(10)
        )
        store.load()
        #expect(store.loadIssue == .writeFailed)
        store.update { $0.general.displayMode = .primary }
        store.flush()
        #expect(store.document.general.displayMode == .primary)
        #expect(store.loadIssue == .writeFailed)
    }

    @Test func unreadableFileThatCannotBeMovedIsNeverOverwritten() throws {
        let dir = try TempDirectory()
        let locked = dir.url.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let config = AppPaths(root: locked).config
        try Data(#"{"schemaVersion":1,"secret":"keep"}"#.utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        }

        let store = ConfigStore(paths: AppPaths(root: locked), defaultWidgetOrder: TestFixtures.defaultOrder, saveDelay: .milliseconds(10))
        store.load()
        #expect(store.loadIssue == .unreadable)
        #expect(store.document == ConfigDefaults.document(catalogOrder: TestFixtures.defaultOrder))

        store.update { $0.general.displayMode = .primary }
        store.flush()
        #expect(store.loadIssue == .unreadable)
        #expect(store.document.general.displayMode == .primary)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        #expect(try String(contentsOf: config, encoding: .utf8) == #"{"schemaVersion":1,"secret":"keep"}"#)
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path) == ["config.json"])
    }

    @Test(arguments: ["symlink", "oversized"])
    func nonRegularOrOversizedFileIsTreatedAsBroken(_ kind: String) throws {
        let dir = try TempDirectory()
        let config = AppPaths(root: dir.url).config
        if kind == "symlink" {
            try FileManager.default.createSymbolicLink(at: config, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        } else {
            try Data(repeating: 0x20, count: AtomicFile.defaultMaxSize + 1).write(to: config)
        }
        let store = makeStore(dir)
        store.load()
        guard case .recoveredBroken(let moved) = store.loadIssue else {
            Issue.record("expected recoveredBroken, got \(String(describing: store.loadIssue))")
            return
        }
        #expect(moved.lastPathComponent.hasPrefix("config.json.broken-"))
        #expect(try AtomicFile(url: config).read() != nil)
    }

    @Test func resetToDefaultsReplacesDocument() throws {
        let dir = try TempDirectory()
        try write(#"{"schemaVersion":1,"x":1,"widgets":[{"id":"clock","enabled":false}]}"#, to: dir)
        let store = makeStore(dir)
        store.load()
        store.resetToDefaults()
        store.flush()
        #expect(store.document == ConfigDefaults.document(catalogOrder: TestFixtures.defaultOrder))
        let json = try TestFixtures.jsonObject(at: AppPaths(root: dir.url).config)
        #expect(json["x"] == nil)
    }

    @Test func reorderKeepsUnknownEntriesInTheirSlots() {
        func entries(_ ids: [String]) -> [WidgetConfigEntry] {
            ids.map { WidgetConfigEntry(id: $0, enabled: true) }
        }
        let result = WidgetOrder.reorder(
            entries: entries(["clock", "X", "timer", "Y", "notes"]),
            knownIDs: ["clock", "timer", "notes"],
            newKnownOrder: ["notes", "clock", "timer"]
        )
        #expect(result.map(\.id) == ["notes", "X", "clock", "Y", "timer"])

        let partial = WidgetOrder.reorder(
            entries: entries(["clock", "X", "timer"]),
            knownIDs: ["clock", "timer"],
            newKnownOrder: ["timer"]
        )
        #expect(partial.map(\.id) == ["timer", "X", "clock"])
    }
}
