@testable import TopoText
import Foundation
import Testing

@Suite struct FileTests {
    let folder: NotesFolder
    let store: Store

    init() throws {
        folder = try NotesFolder.current()
        store = Store(root: folder.root)
    }

    /// The path of a file relative to the Notes folder, after resolving symbolic links.
    func relativePath(_ url: URL?) -> String? {
        guard let url else { return nil }
        let root = folder.root.resolvingSymlinksInPath().path + "/"
        return url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count)) : url.path
    }

    @Test("Media files are found in the account's generation folder")
    func mediaWithGeneration() async throws {
        try folder.writeFile("Accounts/ACCOUNT-1/Media/MEDIA-1/IMG_0001.jpeg")
        try folder.writeFile("Accounts/ACCOUNT-1/Media/MEDIA-1/GEN-1/IMG_0001.jpeg")
        #expect(relativePath(try await store.fileURL(for: .id("IMAGE-1"))) == "Accounts/ACCOUNT-1/Media/MEDIA-1/GEN-1/IMG_0001.jpeg")
    }

    @Test("Media files without a generation folder are found")
    func mediaWithoutGeneration() async throws {
        try folder.writeFile("Accounts/ACCOUNT-1/Media/MEDIA-1/IMG_0001.jpeg")
        #expect(relativePath(try await store.fileURL(for: .id("IMAGE-1"))) == "Accounts/ACCOUNT-1/Media/MEDIA-1/IMG_0001.jpeg")
    }

    @Test("A drawing's fallback image is found")
    func drawing() async throws {
        try folder.writeFile("Accounts/ACCOUNT-1/FallbackImages/DRAWING-1.jpg")
        #expect(relativePath(try await store.fileURL(for: .id("DRAWING-1"))) == "Accounts/ACCOUNT-1/FallbackImages/DRAWING-1.jpg")
        try folder.writeFile("Accounts/ACCOUNT-1/FallbackImages/DRAWING-1/GEN-2/FallbackImage.png")
        #expect(
            relativePath(try await store.fileURL(for: .id("DRAWING-1"))) == "Accounts/ACCOUNT-1/FallbackImages/DRAWING-1/GEN-2/FallbackImage.png"
        )
    }

    @Test("An attachment without a file has no location")
    func noFile() async throws {
        #expect(try await store.fileURL(for: .id("IMAGE-1")) == nil)
        #expect(try await store.fileURL(for: .id("URL-1")) == nil)
    }

    @Test("Folders and links that lead outside the Notes folder are skipped")
    func notRegularOrContained() async throws {
        let path = "Accounts/ACCOUNT-1/Media/MEDIA-1/GEN-1/IMG_0001.jpeg"
        try FileManager.default.createDirectory(at: folder.root.appendingPathComponent(path), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: folder.root.appendingPathComponent("Accounts/ACCOUNT-1/Media/MEDIA-1"),
            withIntermediateDirectories: true
        )
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("topotext-outside-\(UUID().uuidString).jpeg")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: folder.root.appendingPathComponent("Accounts/ACCOUNT-1/Media/MEDIA-1/IMG_0001.jpeg"),
            withDestinationURL: outside
        )
        #expect(try await store.fileURL(for: .id("IMAGE-1")) == nil)
    }

    @Test("Attachments of locked notes and unknown attachments throw")
    func errors() async throws {
        await #expect(throws: NotesError.noteLocked(.id("NOTE-SECRET"))) { try await store.fileURL(for: .id("SECRET-IMAGE")) }
        await #expect(throws: NotesError.attachmentNotFound(.id("NOPE"))) { try await store.fileURL(for: .id("NOPE")) }
        // Inline attachments have no files.
        await #expect(throws: NotesError.attachmentNotFound(.id("HASHTAG-1"))) { try await store.fileURL(for: .id("HASHTAG-1")) }
    }

    @Test("Older stores keep media at the top of the folder")
    func olderStore() async throws {
        let folder = try NotesFolder.older()
        try folder.writeFile("Media/OLD-MEDIA/scan.pdf")
        let url = try await Store(root: folder.root).fileURL(for: .id("OLD-PDF"))
        #expect(url?.lastPathComponent == "scan.pdf")
        #expect(url?.deletingLastPathComponent().lastPathComponent == "OLD-MEDIA")
    }
}
