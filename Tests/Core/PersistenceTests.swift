import Foundation
import Testing
@testable import NotchApp

struct PersistenceTests {
    @Test func backupTimestampIsUTCWithoutColons() {
        #expect(BackupNaming.timestamp(Date(timeIntervalSince1970: 0)) == "19700101-000000")
        #expect(BackupNaming.timestamp(Date(timeIntervalSince1970: 1_700_000_000)) == "20231114-221320")
    }

    @Test func appPathsLayout() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/x"))
        #expect(paths.config.path == "/tmp/x/config.json")
        #expect(paths.data("notes.json").path == "/tmp/x/data/notes.json")
    }

    @Test func atomicFileReadMissingReturnsNil() throws {
        let dir = try TempDirectory()
        #expect(try AtomicFile(url: dir.url.appendingPathComponent("none.json")).read() == nil)
    }

    @Test func atomicFileWriteCreatesParentDirectories() throws {
        let dir = try TempDirectory()
        let file = AtomicFile(url: dir.url.appendingPathComponent("a/b/c.json"))
        try file.write(Data("1".utf8))
        #expect(try file.read() == Data("1".utf8))
        #expect(file.modificationDate() != nil)
    }

    @Test func moveAsideAvoidsCollisions() throws {
        let dir = try TempDirectory()
        let file = AtomicFile(url: dir.url.appendingPathComponent("config.json"))
        try file.write(Data("1".utf8))
        let first = try file.moveAside(suffix: "broken-x")
        try file.write(Data("2".utf8))
        let second = try file.moveAside(suffix: "broken-x")
        #expect(first.lastPathComponent == "config.json.broken-x")
        #expect(second.lastPathComponent == "config.json.broken-x-1")
        #expect(try file.read() == nil)
    }

    private func permissions(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    @Test func writeUsesPrivatePermissions() throws {
        let dir = try TempDirectory()
        let root = dir.url.appendingPathComponent("NotchApp")
        let paths = AppPaths(root: root)
        try AtomicFile(url: paths.config).write(Data("{}".utf8))
        try AtomicFile(url: paths.data("notes.json")).write(Data("{}".utf8))
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(paths.dataDir) == 0o700)
        #expect(try permissions(paths.config) == 0o600)
        #expect(try permissions(paths.data("notes.json")) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func writeTightensExistingWideDirectoryAndOverwrites() throws {
        let dir = try TempDirectory()
        let root = dir.url.appendingPathComponent("NotchApp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let file = AtomicFile(url: root.appendingPathComponent("config.json"))
        try Data("old".utf8).write(to: file.url)
        try file.write(Data("new".utf8))
        #expect(try permissions(root) == 0o700)
        #expect(try permissions(file.url) == 0o600)
        #expect(try file.read() == Data("new".utf8))
    }

    @Test func readRejectsFilesOverLimit() throws {
        let dir = try TempDirectory()
        let file = AtomicFile(url: dir.url.appendingPathComponent("big.json"), maxSize: 16)
        try Data(repeating: 0x20, count: 17).write(to: file.url)
        #expect(throws: AtomicFileError.tooLarge(limit: 16)) { try file.read() }
        try Data(repeating: 0x20, count: 16).write(to: file.url)
        #expect(try file.read()?.count == 16)
    }

    @Test func readRejectsSymlinks() throws {
        let dir = try TempDirectory()
        let target = dir.url.appendingPathComponent("real.json")
        try Data("{}".utf8).write(to: target)
        let link = dir.url.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        #expect(throws: AtomicFileError.notRegularFile) { try AtomicFile(url: link).read() }
    }

    @Test func readRejectsFIFOWithoutBlocking() throws {
        let dir = try TempDirectory()
        let fifo = dir.url.appendingPathComponent("config.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: AtomicFileError.notRegularFile) { try AtomicFile(url: fifo).read() }
    }

    @Test func readRejectsDirectories() throws {
        let dir = try TempDirectory()
        let sub = dir.url.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(throws: AtomicFileError.notRegularFile) { try AtomicFile(url: sub).read() }
    }

    @MainActor
    @Test func debouncedSaverCoalescesBursts() async throws {
        var saves = 0
        let saver = DebouncedSaver(delay: .milliseconds(50)) { saves += 1 }
        for _ in 0..<5 { saver.markDirty() }
        #expect(saves == 0)
        await waitUntil { saves == 1 }
        try await Task.sleep(for: .milliseconds(150))
        #expect(saves == 1)
    }

    @MainActor
    @Test func debouncedSaverFlushWritesImmediatelyOnce() async throws {
        var saves = 0
        let saver = DebouncedSaver(delay: .milliseconds(50)) { saves += 1 }
        saver.markDirty()
        saver.flush()
        #expect(saves == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(saves == 1)
        saver.flush()
        #expect(saves == 1)
    }
}
