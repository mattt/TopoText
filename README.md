# TopoText

TopoText reads the database of the Notes app on macOS.
It lists accounts, folders, and notes,
searches notes by their contents,
and decodes a note's contents into paragraphs of formatted text,
with checklists, tables, and attachments.

TopoText is Apple's internal name for the note text format.

## Requirements

- Xcode 16.3+
- Swift 6.1+
- macOS 15.1+

The caller must have access to the Notes folder,
`~/Library/Group Containers/group.com.apple.notes`,
for example through Full Disk Access or a security-scoped bookmark of the folder.
TopoText does not request permissions or manage security-scoped bookmarks.
The access must cover the folder, not only the database file,
because SQLite also reads the write-ahead log files next to it.
Keep any security scope active until each call returns.

## Installation

### Swift Package Manager

Add TopoText as a dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mattt/TopoText.git", from: "0.1.0")
]
```

Then add the product to your target's dependencies:

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "TopoText", package: "TopoText")
        ]
    )
]
```

## Usage

```swift
import TopoText

let store = Store()  // ~/Library/Group Containers/group.com.apple.notes
try await store.checkAccess()

let folders = try await store.folders()
let result = try await store.search(.init(query: "groceries"))
for note in result.notes {
    print(note.id, note.title, note.modificationDate ?? .distantPast)
}

if let note = result.notes.first, !note.isLocked {
    let content = try await store.content(for: note.id)
    for paragraph in content.paragraphs {
        switch paragraph.style.kind {
        case .checklist:
            print(paragraph.style.isChecked ? "[x]" : "[ ]", paragraph.text)
        default:
            print(paragraph.text)
        }
    }
}
```

### Notes and folders

`folders()` returns every folder except smart folders,
with its account, its parent folder, and its number of notes.
Recently Deleted is a folder, marked by `isRecentlyDeleted`.

`search(_:)` returns notes newest first, by modification date.
Filters combine with AND.
Without a folder filter, a search leaves out Recently Deleted
unless `includesRecentlyDeleted` is `true`.
Dates have an inclusive start and an exclusive end.
The default limit is 30; the maximum is 100.
Pass `nextCursor` from a result as the `cursor` of the next request to get the next page.

A query matches the title, the preview, and the contents,
without regard to case or diacritics.
The contents include the text of tags, mentions, links, tables, and link cards,
attachment names, and the text that Notes recognizes in images and handwriting.
Matching the contents means decoding each note,
so a search examines at most `scanLimit` notes, 1,000 by default.
If it reaches the limit before it finds `limit` matches,
its `nextCursor` continues after the last note it examined.
`unreadableNoteIDs` lists the notes whose contents could not be decoded,
which the search matched by title and preview alone.

Notes that the Notes app doesn't show are left out,
such as drafts of Quick Notes and deleted notes that wait to sync.

### Contents

`content(for:)` returns a note's paragraphs.
Each paragraph has a style (its kind, indent, checked state, starting number,
block quote, and alignment) and runs of text with the same formatting
(bold, italic, underline, strikethrough, superscript or subscript, highlight, color, and link).
Each attachment is a run of one object replacement character (U+FFFC),
with the attachment in the run's `attachment`.
Attachments carry their kind, type identifier, display text, title, URL, file name,
summary, recognized text, and, for a table, its cells as contents of their own.
TopoText reads attachments while it reads the contents,
so rendering the contents does not need the database.
TopoText does not render Markdown or other formats.

`fileURL(for:)` finds the file of an attachment, such as an image, in the Notes folder.

Locked notes keep their contents encrypted.
TopoText lists them, with a `nil` preview, but does not read their contents or files.

Use `withSnapshot(_:)` to read several things from one snapshot of the database,
such as a note and its folders.

### Identifiers

Notes, folders, accounts, and attachments have identifiers from the `ZIDENTIFIER` column.
A note's identifier is a UUID that is the same on every device,
and it is the one in `applenotes:note/<identifier>` links.
`linkedNoteID` on a run or an inline link gives the identifier of the note that the link opens.
Identifiers and cursors encode as strings in JSON.

### Limits and cancellation

`Store` runs one operation at a time on a private dispatch queue.
Each operation opens a read-only connection and closes it before it returns.
TopoText never writes to the database, copies it, or changes its journal mode.
An operation holds a read transaction, which can delay the WAL checkpoints of Notes,
so each operation stops after `Configuration.timeLimit`, 10 seconds by default,
with `NotesError.timedOut`.
Canceling the calling task stops the operation.

### Development

Run the tests and the formatter from the repository root:

```sh
swift test
swift format lint --strict --recursive .
```

The tests use synthetic databases and do not need access to the Notes folder.
They include a port of iMCP's Markdown renderer to check that the contents carry what it needs.

The `Validate` tool reads a real Notes database and prints only aggregate counts,
such as the number of notes whose contents fail to decode,
without titles, text, or identifiers:

```sh
swift run Validate [<path to group.com.apple.notes>] [--applescript]
```

The process that runs it needs access to the Notes folder.
With `--applescript`, it also asks Notes for its count of notes, to compare with the count that TopoText lists.
In a debug build, which `swift run` makes, it also counts the stored fields and values behind the decoded contents.

See [Documentation/NoteStore.md](Documentation/NoteStore.md) for the format and the sources of each fact.

## Acknowledgments

TopoText relies on the reverse engineering of the Notes format in
Jon Baumann's [apple_cloud_notes_parser](https://github.com/threeplanetssoftware/apple_cloud_notes_parser),
for the note protocol buffer and the database schema across releases,
and Steve Dunham's [notesutils](https://github.com/dunhamsteve/notesutils),
for the table CRDT, including how deleted and repeated rows and columns are left out.

These later projects contributed specific facts that TopoText relies on:

- sweetrb's [apple-notes-mcp](https://github.com/sweetrb/apple-notes-mcp),
  from its checks against a live macOS 27 database:
  that drafts of Quick Notes have no folder,
  that Recently Deleted is a folder whose identifier starts with `TrashFolder`
  while rows marked for deletion are already deleted,
  that the newest `ZICNOTEDATA` row holds a note's current contents,
  and that the run covering a paragraph's first character sets its style.
- mgcrea's [cupertino](https://github.com/mgcrea/cupertino),
  from its measurements on macOS 26:
  that requiring a title makes the listed notes match the count from Apple Events,
  and that some `ZICNOTEDATA` rows hold property lists rather than note contents.
- sballin's [alfred-search-notes-app](https://github.com/sballin/alfred-search-notes-app):
  that folders not yet fetched from iCloud should be left out,
  and that a search should include table summaries, tags,
  and the text that Notes recognizes in images and handwriting.
- [Obsidian Importer](https://github.com/obsidianmd/obsidian-importer):
  the order of the creation date columns across releases,
  and how links to other notes name their targets.
- folivoraAI's [BetterTouchTool plugin for Notes](https://github.com/folivoraAI/BetterTouchToolPlugins):
  the starting number of numbered lists.
- 6over3's [NotesKit](https://github.com/6over3/NotesKit):
  following register indirection in tables.

TopoText contains no code from these projects.
[Documentation/NoteStore.md](Documentation/NoteStore.md) lists the source of each fact.

## License

MIT. See [LICENSE.md](LICENSE.md).
