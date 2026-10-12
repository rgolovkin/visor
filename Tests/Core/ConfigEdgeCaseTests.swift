import Foundation
import Testing
@testable import NotchApp

/// Edge cases of ConfigCodec / ConfigStore (AC-13..AC-17).
@MainActor
struct ConfigEdgeCaseTests {
    private func makeStore(_ dir: TempDirectory, delay: Duration = .milliseconds(20)) -> ConfigStore {
        ConfigStore(paths: AppPaths(root: dir.url), defaultWidgetOrder: TestFixtures.defaultOrder, saveDelay: delay)
    }

    private func write(_ json: String, to dir: TempDirectory) throws {
        try Data(json.utf8).write(to: AppPaths(root: dir.url).config)
    }

    private func brokenFiles(_ dir: TempDirectory) throws -> [String] {
        try TestFixtures.files(in: dir.url, prefix: "config.json.broken-")
    }

    // MARK: broken files (AC-14)

    @Test(arguments: ["null", "123", "true", "\"text\"", "   \n\t ", "{\"a\":", "{\"a\":1}}", "{'a':1}", "\u{0}\u{0}\u{0}", "[]"])
    func nonObjectOrInvalidRootIsMovedAside(_ contents: String) throws {
        let dir = try TempDirectory()
        try write(contents, to: dir)
        let store = makeStore(dir)
        store.load()
        guard case .recoveredBroken(let moved) = store.loadIssue else {
            Issue.record("expected recoveredBroken for \(contents.debugDescription), got \(String(describing: store.loadIssue))")
            return
        }
        #expect(try String(contentsOf: moved, encoding: .utf8) == contents)
        #expect(store.document == ConfigDefaults.document(catalogOrder: TestFixtures.defaultOrder))
        // A valid default config must have been written back.
        let json = try TestFixtures.jsonObject(at: AppPaths(root: dir.url).config)
        #expect(json["schemaVersion"] == .number(1))
    }

    @Test func invalidUTF8BinaryIsMovedAside() throws {
        let dir = try TempDirectory()
        let bytes = Data([0xFF, 0xFE, 0x00, 0x7B, 0x80, 0x81])
        try bytes.write(to: AppPaths(root: dir.url).config)
        let store = makeStore(dir)
        store.load()
        guard case .recoveredBroken(let moved) = store.loadIssue else {
            Issue.record("expected recoveredBroken, got \(String(describing: store.loadIssue))")
            return
        }
        #expect(try Data(contentsOf: moved) == bytes)
    }

    @Test func utf8BOMIsEitherReadOrPreservedAsBroken() throws {
        let dir = try TempDirectory()
        let body = Data(#"{"schemaVersion":1,"widgets":[{"id":"clock","enabled":false}]}"#.utf8)
        try (Data([0xEF, 0xBB, 0xBF]) + body).write(to: AppPaths(root: dir.url).config)
        let store = makeStore(dir)
        store.load()
        switch store.loadIssue {
        case nil:
            #expect(store.document.widgets.first?.enabled == false)
        case .recoveredBroken(let moved):
            #expect(try Data(contentsOf: moved).count == body.count + 3)
        default:
            Issue.record("unexpected \(String(describing: store.loadIssue))")
        }
    }

    @Test func configPathBeingADirectoryIsRecovered() throws {
        let dir = try TempDirectory()
        let config = AppPaths(root: dir.url).config
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let store = makeStore(dir)
        store.load()
        guard case .recoveredBroken = store.loadIssue else {
            Issue.record("expected recoveredBroken, got \(String(describing: store.loadIssue))")
            return
        }
        var isDir: ObjCBool = true
        #expect(FileManager.default.fileExists(atPath: config.path, isDirectory: &isDir) && !isDir.boolValue)
    }

    @Test func repeatedBrokenFilesGetDistinctBackupNames() throws {
        let dir = try TempDirectory()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<3 {
            try write("{broken \(i)", to: dir)
            let store = ConfigStore(
                paths: AppPaths(root: dir.url), defaultWidgetOrder: TestFixtures.defaultOrder,
                saveDelay: .milliseconds(10), now: { fixedNow }
            )
            store.load()
            #expect(store.loadIssue != nil)
        }
        let names = try brokenFiles(dir)
        #expect(names.count == 3)
        #expect(Set(names).count == 3)
    }

    @Test func fileOfExactlyMaxSizeIsAccepted() throws {
        let dir = try TempDirectory()
        let head = #"{"schemaVersion":1,"pad":""#
        let tail = #""}"#
        let padCount = AtomicFile.defaultMaxSize - head.utf8.count - tail.utf8.count
        let body = head + String(repeating: "a", count: padCount) + tail
        #expect(body.utf8.count == AtomicFile.defaultMaxSize)
        try write(body, to: dir)
        let store = makeStore(dir)
        store.load()
        #expect(store.loadIssue == nil)
        #expect(store.document.extra["pad"]?.stringValue?.count == padCount)
    }

    // MARK: tolerant decoding

    @Test func nullAndWrongTypedSectionsFallBackToDefaults() throws {
        let doc = try ConfigCodec.decode(Data(#"{"schemaVersion":null,"general":null,"widgets":null}"#.utf8))
        #expect(doc.schemaVersion == 1)
        #expect(doc.general == GeneralConfig())
        #expect(doc.widgets.isEmpty)

        let doc2 = try ConfigCodec.decode(Data(#"{"schemaVersion":"2","general":[1],"widgets":{"id":"clock"}}"#.utf8))
        #expect(doc2.schemaVersion == 1)
        #expect(doc2.general == GeneralConfig())
        #expect(doc2.widgets.isEmpty)
    }

    @Test func wrongTypedGeneralFieldsFallBackIndividually() throws {
        let doc = try ConfigCodec.decode(Data(#"""
        {"general": {"launchAtLogin": 1, "displayMode": 7, "displayId": 42, "displayName": false, "keep": [1]}}
        """#.utf8))
        #expect(doc.general.launchAtLogin == false)
        #expect(doc.general.displayMode == .auto)
        #expect(doc.general.displayId == nil)
        #expect(doc.general.displayName == nil)
        #expect(doc.general.extra == ["keep": .array([.number(1)])])
    }

    @Test func widgetEntriesWithBadShapesAreSkippedOrDefaulted() throws {
        let doc = try ConfigCodec.decode(Data(#"""
        {"widgets": [null, 5, "clock", [], {"id": null}, {"id": 3}, {"id": ""},
                     {"id": "a", "enabled": null, "settings": null},
                     {"id": "b", "enabled": "false", "settings": []},
                     {"id": "c", "enabled": false, "settings": {"x": {"y": [1, 2]}}}]}
        """#.utf8))
        #expect(doc.widgets.map(\.id) == ["a", "b", "c"])
        #expect(doc.widgets[0].enabled == true)
        #expect(doc.widgets[0].settings == .object([:]))
        #expect(doc.widgets[1].enabled == true)   // non-bool falls back to the default (enabled)
        #expect(doc.widgets[1].settings == .object([:]))
        #expect(doc.widgets[2].enabled == false)
        #expect(doc.widgets[2].settings["x"] == .object(["y": .array([.number(1), .number(2)])]))
    }

    @Test func duplicateIdsKeepFirstEntryOnly() throws {
        let doc = try ConfigCodec.decode(Data(#"""
        {"widgets": [{"id":"clock","enabled":false,"settings":{"n":1}},
                     {"id":"timer"},
                     {"id":"clock","enabled":true,"settings":{"n":2}}]}
        """#.utf8))
        #expect(doc.widgets.map(\.id) == ["clock", "timer"])
        #expect(doc.widgets[0].enabled == false)
        #expect(doc.widgets[0].settings["n"] == .number(1))
    }

    @Test(arguments: [0, -1, 1, 2, 99])
    func schemaVersionIsReadAsIs(_ version: Int) throws {
        let doc = try ConfigCodec.decode(Data(#"{"schemaVersion": \#(version)}"#.utf8))
        #expect(doc.schemaVersion == version)
    }

    @Test(arguments: ["1.5", "1e30", "-1e30", "\"x\"", "[]", "true"])
    func nonIntegerSchemaVersionDoesNotCrash(_ raw: String) throws {
        let doc = try ConfigCodec.decode(Data(#"{"schemaVersion": \#(raw)}"#.utf8))
        #expect(doc.schemaVersion == 1)
    }

    // MARK: unknown data preservation (AC-15, AC-16)

    @Test func codecRoundTripKeepsUnknownKeysAtEveryLevelAndIsIdempotent() throws {
        let source = #"""
        {"schemaVersion": 1, "rootNull": null, "rootNested": {"a": [1, {"b": null}]},
         "general": {"launchAtLogin": true, "displayMode": "primary", "displayId": "X", "gUnknown": "я 🙂"},
         "widgets": [{"id": "clock", "enabled": false, "settings": {"deep": {"deeper": [true, null, "s"]}}, "wUnknown": 1.5},
                     {"id": "ёлка-🎄", "enabled": true, "settings": {}, "other": {}}]}
        """#
        let first = try ConfigCodec.decode(Data(source.utf8))
        let encoded = try ConfigCodec.encode(first)
        let second = try ConfigCodec.decode(encoded)
        #expect(first == second)
        // Byte-stable on repeated saves (sorted keys): no churn of the user's file.
        #expect(try ConfigCodec.encode(second) == encoded)

        let json = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(json["rootNull"] == .null)
        #expect(json["rootNested"]?["a"] == .array([.number(1), .object(["b": .null])]))
        #expect(json["general"]?["gUnknown"] == .string("я 🙂"))
        #expect(json["widgets"]?.arrayValue?[0]["wUnknown"] == .number(1.5))
        #expect(json["widgets"]?.arrayValue?[1]["id"] == .string("ёлка-🎄"))
    }

    @Test func deeplyNestedSettingsSurviveARoundTrip() throws {
        let depth = 200
        let nested = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
        let source = #"{"schemaVersion":1,"widgets":[{"id":"clock","enabled":true,"settings":{"deep":\#(nested)}}]}"#
        let started = ContinuousClock.now
        let doc = try ConfigCodec.decode(Data(source.utf8))
        let encoded = try ConfigCodec.encode(doc)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(try ConfigCodec.decode(encoded) == doc)
    }

    @Test(arguments: [600, 100_000])
    func absurdNestingIsRejectedQuicklyAndPreserved(_ depth: Int) throws {
        let dir = try TempDirectory()
        let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let source = #"{"schemaVersion":1,"x":\#(nested)}"#
        try write(source, to: dir)
        let started = ContinuousClock.now
        let store = makeStore(dir)
        store.load()
        #expect(ContinuousClock.now - started < .seconds(5), "decoding of deeply nested input must not blow up")
        guard case .recoveredBroken(let moved) = store.loadIssue else {
            Issue.record("expected recoveredBroken, got \(String(describing: store.loadIssue))")
            return
        }
        #expect(try String(contentsOf: moved, encoding: .utf8) == source)
    }

    @Test func largeIntegersInUnknownFieldsAreNotCorrupted() throws {
        // 2^53 + 1 is not representable as Double; unknown fields must survive "verbatim" (AC-16).
        let source = #"{"schemaVersion":1,"snowflake":9007199254740993,"widgets":[{"id":"x","settings":{"big":9223372036854775807}}]}"#
        let doc = try ConfigCodec.decode(Data(source.utf8))
        let text = String(decoding: try ConfigCodec.encode(doc), as: UTF8.self)
        #expect(text.contains("9007199254740993"), "unknown integer field was altered: \(text)")
        #expect(text.contains("9223372036854775807"), "unknown integer field was altered: \(text)")
    }

    @Test func newerSchemaFileIsNotTouchedUntilFirstChange() throws {
        let dir = try TempDirectory()
        let source = #"{"schemaVersion": 7, "z": 1, "widgets": [{"id":"clock","enabled":true}]}"#
        try write(source, to: dir)
        let store = makeStore(dir)
        store.load()
        store.flush()
        #expect(store.loadIssue == .newerSchema(7))
        #expect(try String(contentsOf: AppPaths(root: dir.url).config, encoding: .utf8) == source)
        #expect(try TestFixtures.files(in: dir.url, prefix: "config.json.v").isEmpty)

        store.update { $0.widgets[0].enabled = false }
        store.flush()
        let backups = try TestFixtures.files(in: dir.url, prefix: "config.json.v7-backup-")
        #expect(backups.count == 1)
        #expect(try String(contentsOf: dir.url.appendingPathComponent(backups[0]), encoding: .utf8) == source)
        #expect(try TestFixtures.jsonObject(at: AppPaths(root: dir.url).config)["schemaVersion"] == .number(7))
    }

    @Test func resetToDefaultsOnNewerSchemaKeepsVersionAndBacksUp() throws {
        let dir = try TempDirectory()
        try write(#"{"schemaVersion": 3, "widgets": []}"#, to: dir)
        let store = makeStore(dir)
        store.load()
        store.resetToDefaults()
        store.flush()
        #expect(try TestFixtures.jsonObject(at: AppPaths(root: dir.url).config)["schemaVersion"] == .number(3))
        #expect(try TestFixtures.files(in: dir.url, prefix: "config.json.v3-backup-").count == 1)
    }

    @Test func unknownWidgetIdsKeepPositionThroughStoreSaveCycles() throws {
        let dir = try TempDirectory()
        try write(#"{"widgets":[{"id":"zzz","settings":{"k":1}},{"id":"clock"},{"id":"yyy","enabled":false}]}"#, to: dir)
        let store = makeStore(dir)
        store.load()
        for i in 0..<5 {
            store.update { $0.widgets[1].enabled = i % 2 == 0 }
            store.flush()
        }
        let ids = try TestFixtures.jsonObject(at: AppPaths(root: dir.url).config)["widgets"]?.arrayValue?.compactMap { $0["id"]?.stringValue }
        #expect(ids == ["zzz", "clock", "yyy"])
    }

    // MARK: persistence robustness (AC-17)

    @Test func failedWriteLeavesOriginalIntactAndNoTempFiles() throws {
        let dir = try TempDirectory()
        let locked = dir.url.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let config = AppPaths(root: locked).config
        let source = #"{"schemaVersion":1,"widgets":[{"id":"clock","enabled":true}]}"#
        try Data(source.utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        let store = ConfigStore(paths: AppPaths(root: locked), defaultWidgetOrder: ["clock"], saveDelay: .milliseconds(10))
        store.load()
        store.update { $0.widgets[0].enabled = false }
        store.flush()
        #expect(store.loadIssue == .writeFailed)
        #expect(store.document.widgets[0].enabled == false)
        #expect(try String(contentsOf: config, encoding: .utf8) == source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path) == ["config.json"])
    }

    @Test func burstOfUpdatesWritesOnlyTheFinalStateAndDeallocWithoutFlushDoesNotCrash() async throws {
        let dir = try TempDirectory()
        var store: ConfigStore? = makeStore(dir, delay: .milliseconds(40))
        store?.load()
        for i in 0..<200 {
            store?.update { $0.general.displayId = "id-\(i)" }
        }
        weak let weakStore = store
        store = nil
        #expect(weakStore == nil, "ConfigStore must not be retained by its pending save task")
        try await Task.sleep(for: .milliseconds(150))
        // The pending debounce was dropped with the store; the file is still the valid default.
        let json = try TestFixtures.jsonObject(at: AppPaths(root: dir.url).config)
        #expect(json["schemaVersion"] == .number(1))
    }

    @Test func burstThenFlushPersistsLastValue() throws {
        let dir = try TempDirectory()
        let store = makeStore(dir, delay: .seconds(30))
        store.load()
        for i in 0..<200 {
            store.update { $0.general.displayId = "id-\(i)" }
        }
        store.flush()
        #expect(try TestFixtures.jsonObject(at: AppPaths(root: dir.url).config)["general"]?["displayId"] == .string("id-199"))
    }

    @Test func defaultDebounceFitsInsideFiveHundredMilliseconds() async throws {
        let dir = try TempDirectory()
        let store = ConfigStore(paths: AppPaths(root: dir.url), defaultWidgetOrder: TestFixtures.defaultOrder)
        store.load()
        let configURL = AppPaths(root: dir.url).config
        let started = ContinuousClock.now
        store.update { $0.general.displayMode = .notch }
        await waitUntil(timeout: .seconds(2)) {
            (try? TestFixtures.jsonObject(at: configURL))?["general"]?["displayMode"] == .string("notch")
        }
        // 300 ms configured delay + scheduler tolerance; generous slack for a busy machine.
        #expect(ContinuousClock.now - started < .milliseconds(750))
    }

    @Test func writtenConfigMatchesTheDocumentedShape() throws {
        let dir = try TempDirectory()
        let store = makeStore(dir)
        store.load()
        let json = try TestFixtures.jsonObject(at: AppPaths(root: dir.url).config)
        #expect(Set(json.keys) == ["schemaVersion", "general", "widgets"])
        #expect(Set(json["general"]?.objectValue?.keys.map { $0 } ?? []) == ["launchAtLogin", "displayMode", "displayId"])
        for widget in json["widgets"]?.arrayValue ?? [] {
            #expect(Set(widget.objectValue?.keys.map { $0 } ?? []) == ["id", "enabled", "settings"])
            #expect(widget["settings"] == .object([:]))
        }
    }
}
