import Foundation
import Observation

/// Owns config.json. All access happens on the main actor: the file is a few KB, and a synchronous
/// `flush()` on quit must finish before the process exits (ADR-002).
@MainActor
@Observable
final class ConfigStore {
    private(set) var document: ConfigDocument
    private(set) var loadIssue: ConfigLoadIssue?

    @ObservationIgnored private let file: AtomicFile
    @ObservationIgnored private let defaultWidgetOrder: [String]
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var saver: DebouncedSaver?
    /// `false` when the existing file could not be read or moved aside: never overwrite it then.
    @ObservationIgnored private var canPersist = true
    @ObservationIgnored private var pendingVersionBackup: Int?

    init(
        paths: AppPaths,
        defaultWidgetOrder: [String],
        saveDelay: Duration = .milliseconds(300),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.file = AtomicFile(url: paths.config)
        self.defaultWidgetOrder = defaultWidgetOrder
        self.now = now
        self.document = ConfigDefaults.document(catalogOrder: defaultWidgetOrder)
        self.saver = nil
        self.saver = DebouncedSaver(delay: saveDelay) { [weak self] in self?.save() }
    }

    func load() {
        let data: Data?
        do {
            data = try file.read()
        } catch {
            Log.config.error("Cannot read config: \(error.localizedDescription, privacy: .public)")
            recoverFromBrokenFile()
            return
        }

        guard let data else {
            Log.config.info("No config found, creating defaults")
            document = ConfigDefaults.document(catalogOrder: defaultWidgetOrder)
            loadIssue = .createdDefault
            save()
            return
        }

        do {
            document = try ConfigCodec.decode(data)
        } catch {
            Log.config.error("Config is not valid JSON: \(error.localizedDescription, privacy: .public)")
            recoverFromBrokenFile()
            return
        }

        if document.schemaVersion > ConfigCodec.currentSchemaVersion {
            Log.config.warning(
                "Config schemaVersion \(self.document.schemaVersion) is newer than supported \(ConfigCodec.currentSchemaVersion); reading known fields only"
            )
            loadIssue = .newerSchema(document.schemaVersion)
            pendingVersionBackup = document.schemaVersion
        }
    }

    func update(_ mutate: (inout ConfigDocument) -> Void) {
        var copy = document
        mutate(&copy)
        guard copy != document else { return }
        document = copy
        saver?.markDirty()
    }

    func flush() {
        saver?.flush()
    }

    /// Unknown fields are dropped too: this is an explicit reset. `data/` is not touched.
    func resetToDefaults() {
        var defaults = ConfigDefaults.document(catalogOrder: defaultWidgetOrder)
        defaults.schemaVersion = max(defaults.schemaVersion, document.schemaVersion)
        guard defaults != document else { return }
        document = defaults
        saver?.markDirty()
    }

    private func recoverFromBrokenFile() {
        document = ConfigDefaults.document(catalogOrder: defaultWidgetOrder)
        do {
            let moved = try file.moveAside(suffix: "broken-\(BackupNaming.timestamp(now()))")
            Log.config.warning("Broken config moved to \(moved.lastPathComponent, privacy: .public)")
            loadIssue = .recoveredBroken(moved)
            save()
        } catch {
            Log.config.error(
                "Cannot move broken config aside, working in memory only: \(error.localizedDescription, privacy: .public)"
            )
            canPersist = false
            loadIssue = .unreadable
        }
    }

    private func save() {
        guard canPersist else { return }

        if let version = pendingVersionBackup {
            do {
                let backup = try file.copy(suffix: "v\(version)-backup-\(BackupNaming.timestamp(now()))")
                Log.config.warning("Backed up newer config to \(backup.lastPathComponent, privacy: .public)")
                pendingVersionBackup = nil
            } catch {
                Log.config.error(
                    "Cannot back up newer config, skipping write: \(error.localizedDescription, privacy: .public)"
                )
                loadIssue = .writeFailed
                return
            }
        }

        do {
            try file.write(try ConfigCodec.encode(document))
        } catch {
            Log.config.error("Cannot write config: \(error.localizedDescription, privacy: .public)")
            loadIssue = .writeFailed
        }
    }
}
