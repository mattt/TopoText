import Foundation

extension Database {
    /// Returns the places in the Notes folder where an attachment's file can be, most likely first.
    ///
    /// Notes keeps attachment files below `Accounts/<account identifier>/`,
    /// and older stores and On My Mac keep some at the top of the folder:
    ///
    /// - Media: `Media/<media identifier>/<generation>/<file name>`,
    ///   without the generation folder before iOS 17 and macOS 14
    /// - Drawings: `FallbackImages/<attachment identifier>/<generation>/FallbackImage.png`,
    ///   or `FallbackImages/<attachment identifier>.png` or `.jpg` in older stores
    /// - Scanned documents: `FallbackPDFs/<attachment identifier>/<generation>/FallbackPDF.pdf`,
    ///   or `FallbackPDFs/<attachment identifier>.pdf` in older stores
    ///
    /// - Throws: ``NotesError/attachmentNotFound(_:)`` if the database has no such attachment,
    ///   or ``NotesError/noteLocked(_:)`` if its note is locked, which leaves its files encrypted.
    func fileCandidates(for identifier: Note.Attachment.ID) throws -> [URL] {
        let entityCondition = entities["ICAttachment"].map { "AND a.Z_ENT = \($0)" } ?? ""
        let sql = """
            SELECT \(coalesce("a", "ZTYPEUTI1", "ZTYPEUTI")), m.ZIDENTIFIER, \(column("m", "ZFILENAME")),
                \(coalesce("m", "ZGENERATION1", "ZGENERATION")),
                \(column("a", "ZFALLBACKIMAGEGENERATION")), \(column("a", "ZFALLBACKPDFGENERATION")),
                account.ZIDENTIFIER, n.ZIDENTIFIER, \(column("n", "ZISPASSWORDPROTECTED"))
            FROM ZICCLOUDSYNCINGOBJECT a
            LEFT JOIN ZICCLOUDSYNCINGOBJECT m ON m.Z_PK = \(column("a", "ZMEDIA"))
            LEFT JOIN ZICCLOUDSYNCINGOBJECT n ON n.Z_PK = \(column("a", "ZNOTE"))
            LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = \(column("n", "ZFOLDER"))
            LEFT JOIN ZICCLOUDSYNCINGOBJECT account ON account.Z_PK = \(column("f", "ZOWNER"))
            WHERE a.ZIDENTIFIER = ? \(entityCondition)
            LIMIT 1
            """
        typealias Values = (
            type: String?, media: String?, fileName: String?, generation: String?,
            imageGeneration: String?, pdfGeneration: String?, account: String?, note: String?, isLocked: Bool
        )
        let values = try query(sql, [.text(identifier.description)]) { row -> Values in
            (
                row.text(0), row.text(1), row.text(2), row.text(3),
                row.text(4), row.text(5), row.text(6), row.text(7), row.integer(8) == 1
            )
        }
        guard let values = values.first else {
            throw NotesError.attachmentNotFound(identifier)
        }
        if values.isLocked, let note = values.note.flatMap(Note.ID.init(_:)) {
            throw NotesError.noteLocked(note)
        }

        /// The value as one path component, or `nil` if it is empty or could leave its folder.
        func component(_ value: String?) -> String? {
            guard let value, !value.isEmpty, value != ".", value != "..", !value.contains("/") else { return nil }
            return value
        }

        let attachment = component(identifier.description)
        var media: [String] = []
        if let folder = component(values.media), let file = component(values.fileName) {
            if let generation = component(values.generation) {
                media.append("Media/\(folder)/\(generation)/\(file)")
            }
            media.append("Media/\(folder)/\(file)")
        }
        var images: [String] = []
        var pdfs: [String] = []
        if let attachment {
            if let generation = component(values.imageGeneration) {
                images.append("FallbackImages/\(attachment)/\(generation)/FallbackImage.png")
            }
            images += ["FallbackImages/\(attachment).png", "FallbackImages/\(attachment).jpg"]
            if let generation = component(values.pdfGeneration) {
                pdfs.append("FallbackPDFs/\(attachment)/\(generation)/FallbackPDF.pdf")
            }
            pdfs.append("FallbackPDFs/\(attachment).pdf")
        }

        // A drawing's viewable form is its fallback image, and a scan's is its fallback PDF.
        let paths: [String]
        switch Note.Attachment.kind(of: values.type ?? "") {
        case .drawing: paths = images + media + pdfs
        case .scannedDocument: paths = pdfs + media + images
        default: paths = media + pdfs + images
        }

        var folders: [URL] = []
        if let account = component(values.account) {
            folders.append(root.appendingPathComponent("Accounts").appendingPathComponent(account))
        }
        folders.append(root)
        return folders.flatMap { folder in paths.map { folder.appendingPathComponent($0) } }
    }

    /// Returns the first of the candidates that is a regular file inside the Notes folder.
    ///
    /// Symbolic links are resolved, and a file that resolves outside the folder is skipped.
    static func firstFile(in candidates: [URL], root: URL) -> URL? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        for candidate in candidates {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/"),
                (try? resolved.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            return resolved
        }
        return nil
    }
}
