import Foundation

struct AppPaths: Sendable {
    static let appFolderName = "NotchApp"

    let root: URL

    var config: URL { root.appendingPathComponent("config.json", isDirectory: false) }
    var dataDir: URL { root.appendingPathComponent("data", isDirectory: true) }

    func data(_ name: String) -> URL {
        dataDir.appendingPathComponent(name, isDirectory: false)
    }

    static func standard() throws -> AppPaths {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return AppPaths(root: base.appendingPathComponent(appFolderName, isDirectory: true))
    }
}
