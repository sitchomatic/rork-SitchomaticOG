import Foundation

nonisolated struct NordLynxZipService: Sendable {
    func createZip(from directoryURL: URL, zipName: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let namedDir = tempDir.appending(path: zipName)
        try FileManager.default.copyItem(at: directoryURL, to: namedDir)

        let zipURL = tempDir.appending(path: "\(zipName).zip")

        var error: NSError?
        var innerError: (any Error)?

        NSFileCoordinator().coordinate(
            readingItemAt: namedDir,
            options: .forUploading,
            error: &error
        ) { tempZipURL in
            do {
                try FileManager.default.moveItem(at: tempZipURL, to: zipURL)
            } catch {
                innerError = error
            }
        }

        if let error { throw error }
        if let innerError { throw innerError }

        return zipURL
    }
}
