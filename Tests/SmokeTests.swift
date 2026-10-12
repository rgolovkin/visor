import Foundation
import Testing
@testable import NotchApp

struct SmokeTests {
    @Test func hostAppDetectsUnitTestEnvironment() async {
        let detected = await MainActor.run { AppDelegate.isRunningUnitTests }
        #expect(detected)
    }

    @Test func tempDirectoryIsCreatedAndRemoved() throws {
        var path: URL?
        do {
            let dir = try TempDirectory()
            path = dir.url
            #expect(FileManager.default.fileExists(atPath: dir.url.path))
        }
        #expect(path.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }
}
