import AppKit
import Foundation
import Testing
@testable import NotchApp

/// Structural guarantees that stand in for "0% CPU at idle" (NFR) and packaging/AC checks that need no UI.
/// The source tree is located from this file's path (`#filePath`), so these tests need the checkout on disk.
struct StructureTests {
    private static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static let sourceDirs = ["App", "Window", "Core", "Widgets", "Settings"]

    private static func swiftFiles() -> [URL] {
        var result: [URL] = []
        for dir in sourceDirs {
            let base = root.appendingPathComponent(dir)
            guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" { result.append(url) }
        }
        return result
    }

    private static func strippedSource(_ url: URL) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func sourceTreeIsReachable() {
        #expect(Self.swiftFiles().count > 30, "root: \(Self.root.path)")
    }

    @Test(arguments: [
        "Timer.scheduledTimer", "Timer(timeInterval", "Timer.publish", "NSTimer", "DispatchSource", "CVDisplayLink",
        "Thread.sleep", "usleep(", "asyncAfter", "performSelector", ".repeatForever", "TimelineView",
        "CADisplayLink", "DispatchQueue.main.async", "RunLoop.main.add",
    ])
    func noPollingPrimitivesInProductionCode(_ pattern: String) {
        for file in Self.swiftFiles() {
            let text = Self.strippedSource(file)
            #expect(!text.contains(pattern), "\(file.lastPathComponent) uses \(pattern)")
        }
    }

    /// Delays are one-shot `Task.sleep`s owned by three audited types; anything new must be reviewed.
    @Test func taskSleepIsOnlyUsedByAuditedOneShotTimers() {
        let allowed: Set<String> = ["OneShotScheduler.swift", "DebouncedSaver.swift", "NotchViewModel.swift"]
        for file in Self.swiftFiles() where Self.strippedSource(file).contains("Task.sleep") {
            #expect(allowed.contains(file.lastPathComponent), "unaudited Task.sleep in \(file.lastPathComponent)")
        }
    }

    @Test func noSleepInsideLoopsInAuditedFiles() {
        for name in ["OneShotScheduler.swift", "DebouncedSaver.swift", "NotchViewModel.swift"] {
            guard let file = Self.swiftFiles().first(where: { $0.lastPathComponent == name }) else {
                Issue.record("missing \(name)")
                continue
            }
            let text = Self.strippedSource(file)
            #expect(!text.contains("while "), "\(name) contains a while loop")
            #expect(!text.contains("for await"), "\(name) contains a for-await loop")
        }
    }

    @Test func noThirdPartyImports() {
        let allowed: Set<String> = ["AppKit", "Foundation", "SwiftUI", "Observation", "CoreGraphics", "Darwin", "os", "OSLog", "Combine", "ServiceManagement"]
        for file in Self.swiftFiles() {
            for line in Self.strippedSource(file).split(separator: "\n") where line.hasPrefix("import ") {
                let module = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                #expect(allowed.contains(module), "\(file.lastPathComponent) imports \(module)")
            }
        }
    }

    @Test func noPrintOrNSLogInProductionCode() {
        for file in Self.swiftFiles() {
            let text = Self.strippedSource(file)
            #expect(!text.contains("print("), "\(file.lastPathComponent) uses print")
            #expect(!text.contains("NSLog("), "\(file.lastPathComponent) uses NSLog")
        }
    }

    // AC-20
    @Test func menuBarHasSettingsAndQuitWithShortcuts() throws {
        let text = Self.strippedSource(Self.root.appendingPathComponent("App/MenuBarContent.swift"))
        #expect(text.contains("Settings…"))
        #expect(text.contains(#".keyboardShortcut(",")"#))
        #expect(text.contains("terminate(nil)"))
        #expect(text.contains(#".keyboardShortcut("q")"#))
    }

    // AC-10 (no Dock / Cmd+Tab)
    @Test func appIsAnAgentWithoutDockIcon() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String == "14.0")
        let localizations = Bundle.main.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String]
        #expect(Set(localizations ?? []) == ["en", "ru"])
    }

    /// Q6: every user-visible key has a Russian translation.
    @Test func stringCatalogHasRussianForEveryTranslatableKey() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/Localizable.xcstrings"))
        let catalog = try JSONDecoder().decode(JSONValue.self, from: data)
        let strings = try #require(catalog["strings"]?.objectValue)
        for (key, value) in strings where key != "NotchApp" {
            let russian = value["localizations"]?["ru"]?["stringUnit"]?["value"]?.stringValue
            #expect(russian?.isEmpty == false, "missing ru translation for \(key)")
            #expect(value["localizations"]?["ru"]?["stringUnit"]?["state"]?.stringValue == "translated", "\(key) not marked translated")
        }
        #expect(catalog["sourceLanguage"]?.stringValue == "en")
    }

    // AC-13: catalog order equals the specification.
    @MainActor @Test func defaultWidgetOrderMatchesSpecification() {
        #expect(WidgetCatalog.defaultOrder == ["clock", "calendar", "timer", "battery", "weather", "sysmon", "notes"])
        #expect(Set(WidgetCatalog.defaultOrder).count == 7)
        #expect(WidgetCatalog.all.allSatisfy { WidgetCatalog.defaultOrder.contains($0.id) })
    }

    @Test func standardPathsPointToApplicationSupportNotchApp() throws {
        let paths = try AppPaths.standard()
        #expect(paths.config.path.hasSuffix("/Library/Application Support/NotchApp/config.json"))
        #expect(paths.data("notes.json").path.hasSuffix("/NotchApp/data/notes.json"))
    }
}
