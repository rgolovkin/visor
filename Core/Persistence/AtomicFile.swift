import Darwin
import Foundation

enum AtomicFileError: Error, Equatable {
    case notRegularFile
    case tooLarge(limit: Int)
    case posix(operation: String, code: Int32)
}

/// Small JSON files owned by the app. Directories are created `0700`, files `0600`; reads are bounded
/// and only accept regular files (no symlinks, FIFOs or devices), so a bad file cannot hang the main thread.
struct AtomicFile: Sendable {
    static let defaultMaxSize = 4 * 1024 * 1024
    static let directoryPermissions: mode_t = 0o700
    static let filePermissions: mode_t = 0o600

    let url: URL
    var maxSize: Int = AtomicFile.defaultMaxSize

    /// Returns `nil` when the file does not exist; throws on any other problem.
    func read() throws -> Data? {
        // O_NOFOLLOW: a symlink fails with ELOOP; O_NONBLOCK: opening a FIFO does not block.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            if code == ENOENT { return nil }
            if code == ELOOP { throw AtomicFileError.notRegularFile }
            throw AtomicFileError.posix(operation: "open", code: code)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw AtomicFileError.posix(operation: "fstat", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw AtomicFileError.notRegularFile }
        guard info.st_size <= off_t(maxSize) else { throw AtomicFileError.tooLarge(limit: maxSize) }

        let data = try handle.read(upToCount: maxSize + 1) ?? Data()
        guard data.count <= maxSize else { throw AtomicFileError.tooLarge(limit: maxSize) }
        return data
    }

    /// Writes a `0600` temporary file next to the target, fsyncs it and renames it over the target,
    /// so readers see either the old or the new content and the file is never world-readable.
    func write(_ data: Data) throws {
        let directory = url.deletingLastPathComponent()
        try Self.prepareDirectory(directory)

        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, Self.filePermissions)
        guard fd >= 0 else { throw AtomicFileError.posix(operation: "open", code: errno) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temp.path, url.path) == 0 else {
                throw AtomicFileError.posix(operation: "rename", code: errno)
            }
        } catch {
            unlink(temp.path)
            throw error
        }
    }

    /// Renames the file to `<name>.<suffix>` (adds `-1`, `-2`… if taken) and returns the new URL.
    @discardableResult
    func moveAside(suffix: String) throws -> URL {
        let target = freeSiblingURL(suffix: suffix)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    @discardableResult
    func copy(suffix: String) throws -> URL {
        let target = freeSiblingURL(suffix: suffix)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    func modificationDate() -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    /// Creates the directory (and missing parents) as `0700`, and tightens it if an older build
    /// created it with default permissions.
    private static func prepareDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Int(directoryPermissions)]
        )
        let current = (try? manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int) ?? 0
        if current & 0o077 != 0 {
            try manager.setAttributes([.posixPermissions: Int(directoryPermissions)], ofItemAtPath: directory.path)
        }
    }

    private func freeSiblingURL(suffix: String) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent).\(suffix)"
        var candidate = directory.appendingPathComponent(base, isDirectory: false)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter)", isDirectory: false)
            counter += 1
        }
        return candidate
    }
}
