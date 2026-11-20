import Foundation
import TopoText

// Compares the reads of tags, note links, and smart folders, which follow database rows,
// with what the decoded note contents hold.
// Like the rest of the tool, it prints only counts and JSON types,
// never tag names, link labels, identifiers, or folder names,
// except that `--smart-folders` prints each smart folder's name and stored query.

/// The tags and note links that a note's decoded contents hold, including those in table cells.
struct DecodedInline: Sendable {
    /// The tags, compared as Notes compares them.
    var tags: Set<String> = []
    /// The number of tag attachments without text, which can't be compared.
    var tagsWithoutText = 0
    /// The notes that inline note links open.
    var linkTargets: Set<Note.ID> = []
    /// The number of inline note links without a note identifier, which can't be compared.
    var linksWithoutTarget = 0
    /// The number of text runs whose link opens a note, which the row-based reads don't cover.
    var runLinksToNotes = 0
}

/// Describes the form of a stored value without what it identifies.
///
/// Punctuation stays, and so do the words of the known link forms,
/// `applenotes://showNote?identifier=…` and `applenotes:note/…?ownerIdentifier=…`.
/// Every other run of letters, digits, and hyphens becomes its length and kind,
/// so `applenotes:note/0E5A3C7D-1111-4B4B-8C8C-000000000001` becomes
/// `applenotes:note/<36 hex digits and hyphens, uppercase>`.
func maskedShape(_ text: String?) -> String {
    guard let text else { return "none" }
    let known: Set<String> = ["applenotes", "note", "owneridentifier", "shownote", "identifier"]
    var shape = ""
    var run = ""
    func flush() {
        guard !run.isEmpty else { return }
        defer { run = "" }
        if known.contains(run.lowercased()) {
            shape += run
            return
        }
        let letters = run.filter(\.isLetter)
        let letterCase =
            letters.isEmpty
            ? "" : letters.allSatisfy(\.isUppercase) ? ", uppercase" : letters.allSatisfy(\.isLowercase) ? ", lowercase" : ", mixed case"
        let isHex = run.allSatisfy { $0 == "-" || $0.isHexDigit }
        shape += "<\(run.count) \(isHex ? "hex digits and hyphens" : "letters and digits")\(letterCase)>"
    }
    for character in text {
        // Characters outside ASCII are masked too, whatever they are.
        if character.isLetter || character.isNumber || character == "-" || !character.isASCII {
            run.append(character)
        } else {
            flush()
            shape.append(character)
        }
    }
    flush()
    return shape
}

/// Returns a tag's name as Notes compares it: lowercased, without diacritics.
///
/// TopoText compares tags the same way, but its key is internal.
func tagKey(_ tag: Note.Tag) -> String {
    tag.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

/// Counts that compare the row-based reads with decoded contents, in the order they print.
struct InlineChecks: Sendable {
    /// The most link targets whose backlinks the tool checks.
    static let backlinkSampleSize = 200

    private(set) var counts: [String: Int] = [:]
    private var labels: [String] = []
    /// The number of notes that the per-note read gives each tag, keyed by ``tagKey(_:)``.
    private var notesByTag: [String: Int] = [:]
    /// The notes that link to each note, from the per-note read, without links from a note to itself.
    private var sourcesByTarget: [Note.ID: Set<Note.ID>] = [:]

    mutating func add(_ label: String, _ amount: Int = 1) {
        if counts[label] == nil {
            labels.append(label)
        }
        counts[label, default: 0] += amount
    }

    /// Adds the labels in a fixed order, so that a count of zero still prints.
    init() {
        for label in [
            "tags of a note: notes compared",
            "tags of a note: notes where the rows and the contents agree",
            "tags of a note: notes where the rows hold a tag that the contents lack",
            "tags of a note: notes where the contents hold a tag that the rows lack",
            "tags of a note: tag attachments in the contents without text, not compared",
            "links from a note: notes compared",
            "links from a note: notes where the rows and the contents agree",
            "links from a note: notes where the rows hold a link that the contents lack",
            "links from a note: notes where the contents hold a link that the rows lack",
            "links from a note: inline links in the contents without a note identifier, not compared",
            "links from a note: notes with text-run links to notes, which links(from:) doesn't read",
            "notes not compared: locked",
            "notes not compared: in Recently Deleted",
            "notes not compared: contents not decoded",
        ] {
            add(label, 0)
        }
    }

    mutating func merge(_ other: InlineChecks) {
        for label in other.labels {
            add(label, other.counts[label] ?? 0)
        }
        notesByTag.merge(other.notesByTag, uniquingKeysWith: +)
        sourcesByTarget.merge(other.sourcesByTarget) { $0.union($1) }
    }

    /// Compares the per-note reads of a page of notes with the contents decoded from them.
    ///
    /// - Parameters:
    ///   - notes: The notes of the page.
    ///   - decoded: The tags and links decoded from each note whose contents decoded.
    ///   - snapshot: The snapshot that the page was read from.
    mutating func compare(_ notes: [Note], decoded: [Note.ID: DecodedInline], in snapshot: Store.Snapshot) throws {
        // The per-note reads leave out locked notes and notes in Recently Deleted, so the comparison does too.
        var readable: [Note.ID] = []
        for note in notes {
            if note.isLocked {
                add("notes not compared: locked")
            } else if note.isRecentlyDeleted {
                add("notes not compared: in Recently Deleted")
            } else {
                readable.append(note.id)
                if decoded[note.id] == nil { add("notes not compared: contents not decoded") }
            }
        }
        let rowTags = try snapshot.tags(for: readable)
        let rowLinks = try snapshot.links(from: readable)

        for id in readable {
            let tags = Set((rowTags[id] ?? []).map(tagKey))
            for tag in tags {
                notesByTag[tag, default: 0] += 1
            }
            let links = rowLinks[id] ?? []
            for link in links where link.targetID != id {
                sourcesByTarget[link.targetID, default: []].insert(id)
            }

            guard let found = decoded[id] else { continue }
            compare(rows: tags, contents: found.tags, prefix: "tags of a note", noun: "tag")
            compare(rows: Set(links.map(\.targetID)), contents: found.linkTargets, prefix: "links from a note", noun: "link")
            add("tags of a note: tag attachments in the contents without text, not compared", found.tagsWithoutText)
            add("links from a note: inline links in the contents without a note identifier, not compared", found.linksWithoutTarget)
            if found.runLinksToNotes > 0 {
                add("links from a note: notes with text-run links to notes, which links(from:) doesn't read")
            }
        }
    }

    private mutating func compare<Value>(rows: Set<Value>, contents: Set<Value>, prefix: String, noun: String) {
        add("\(prefix): notes compared")
        if rows == contents {
            add("\(prefix): notes where the rows and the contents agree")
        }
        if !rows.isSubset(of: contents) {
            add("\(prefix): notes where the rows hold a \(noun) that the contents lack")
        }
        if !contents.isSubset(of: rows) {
            add("\(prefix): notes where the contents hold a \(noun) that the rows lack")
        }
    }

    /// Compares the tag inventory and a sample of backlinks with the per-note reads.
    ///
    /// Call it after ``compare(_:decoded:in:)`` has seen every page.
    mutating func checkInventoryAndBacklinks(in snapshot: Store.Snapshot) throws {
        let inventory = try snapshot.tags(includingRecentlyDeleted: false)
        let inventoryWithDeleted = try snapshot.tags(includingRecentlyDeleted: true)
        add("tag inventory: tags, without Recently Deleted", inventory.count)
        add("tag inventory: tags, with Recently Deleted", inventoryWithDeleted.count)
        let counts = Dictionary(inventory.map { (tagKey($0.tag), $0.noteCount) }, uniquingKeysWith: +)
        let differing = Set(counts.keys).union(notesByTag.keys).filter { counts[$0] != notesByTag[$0] }
        add("tag inventory: tags whose note count differs from the per-note read", differing.count)
        add("tag inventory: tags listed more than once", inventory.count - counts.count)

        add("backlinks: link targets found by the per-note read", sourcesByTarget.count)
        // Sort by identifier, so that every run checks the same sample.
        let sample = sourcesByTarget.keys.sorted { $0.description < $1.description }.prefix(Self.backlinkSampleSize)
        add("backlinks: targets checked (at most \(Self.backlinkSampleSize))", sample.count)
        add("backlinks: targets where backlinks(to:) agrees with the reversed links", 0)
        add("backlinks: targets where backlinks(to:) differs from the reversed links", 0)
        for target in sample {
            let sources = Set(try snapshot.backlinks(to: target).map(\.sourceID))
            if sources == sourcesByTarget[target] {
                add("backlinks: targets where backlinks(to:) agrees with the reversed links")
            } else {
                add("backlinks: targets where backlinks(to:) differs from the reversed links")
            }
        }
    }

    /// The counts, in the order in which they were first added.
    var lines: [String] {
        labels.map { "\($0): \(counts[$0] ?? 0)" }
    }
}

// MARK: Smart folders

/// Returns lines that describe the smart folders: their number, how many queries are valid JSON,
/// and a histogram of query shapes.
///
/// A shape is the query's key structure with every value replaced by its JSON type.
/// A key that isn't a plain ASCII word, or that matches a tag, prints as `<key>`,
/// so that a query that keys by tag name doesn't reveal it.
func smartFolderLines(_ folders: [SmartFolder], tagKeys: Set<String>) -> [String] {
    var shapes: [String: Int] = [:]
    var valid = 0
    for folder in folders {
        guard let object = try? JSONSerialization.jsonObject(with: Data(folder.query.utf8), options: [.fragmentsAllowed]) else {
            shapes["not valid JSON", default: 0] += 1
            continue
        }
        valid += 1
        shapes[jsonShape(object, tagKeys: tagKeys), default: 0] += 1
    }
    var lines = [
        "smart folders: \(folders.count)",
        "smart folders: queries that are valid JSON: \(valid)",
    ]
    for (shape, count) in shapes.sorted(by: { ($1.value, $0.key) < ($0.value, $1.key) }) {
        lines.append("smart folder query shape: \(shape): \(count)")
    }
    return lines
}

/// Returns the key structure of a JSON value, with each value replaced by its type.
///
/// An array shows the distinct shapes of its elements, in the order they first appear.
func jsonShape(_ value: Any, tagKeys: Set<String>) -> String {
    switch value {
    case let dictionary as [String: Any]:
        let members = dictionary.keys.sorted().map { key in
            "\(printableKey(key, tagKeys: tagKeys)):\(jsonShape(dictionary[key]!, tagKeys: tagKeys))"
        }
        return "{" + members.joined(separator: ",") + "}"
    case let array as [Any]:
        var seen: [String] = []
        for element in array {
            let shape = jsonShape(element, tagKeys: tagKeys)
            if !seen.contains(shape) {
                seen.append(shape)
            }
        }
        return "[" + seen.joined(separator: "|") + "]"
    case let number as NSNumber:
        return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
    case is String:
        return "string"
    case is NSNull:
        return "null"
    default:
        return "unknown"
    }
}

/// Returns a JSON key as it prints in a shape.
private func printableKey(_ key: String, tagKeys: Set<String>) -> String {
    let isWord = !key.isEmpty && key.count <= 40 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    let isTag = tagKeys.contains(key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    return isWord && !isTag ? key : "<key>"
}
