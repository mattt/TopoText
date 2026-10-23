# TopoText

TopoText reads the Notes app's database on macOS.
It lists folders and notes,
searches notes by their contents,
and decodes each note into paragraphs of formatted text,
including checklists, tables, and attachments.

The name comes from Apple's internal name for the note text format.

## Requirements

- macOS 15.1+
- Swift 6.1+ (Xcode 16.3+)

Your app needs read access to `~/Library/Group Containers/group.com.apple.notes`,
through Full Disk Access or a security-scoped bookmark for that folder.
Grant access to the whole folder, not just `NoteStore.sqlite`;
SQLite also reads the write-ahead log files next to it.

## Installation

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/mattt/TopoText.git", from: "0.1.0")
```

Then add `.product(name: "TopoText", package: "TopoText")` to your target's dependencies.

## Usage

```swift
import TopoText

let store = TopoText.Store()  // ~/Library/Group Containers/group.com.apple.notes
try await store.checkAccess()

let folders = try await store.folders()
let result = try await store.search(.init(query: "groceries"))
for note in result.notes {
    print(note.id, note.title, note.modificationDate ?? .distantPast)
}

if let note = result.notes.first, !note.isLocked {
    let content = try await store.content(for: note.id)
    print(content.markdown())
}
```

`search(_:)` returns notes newest first, 30 at a time by default.
To get the next page, pass the result's `nextCursor` back in the request.
A query matches titles, previews, and contents, ignoring case and diacritics.
Matching contents means decoding each note,
so a search looks at no more than `scanLimit` notes (1,000 by default)
and returns a cursor if it stops early.
Notes in Recently Deleted are left out unless you ask for them.

`content(for:)` returns paragraphs, each with a style and runs of formatted text.
An attachment, such as a tag, an image, or a table, is a run with an `attachment`.
Tables come with their cells decoded,
so you can render a note without going back to the database.
`fileURL(for:)` finds the file for an image or another attachment.

`markdown()` renders contents as Markdown,
with headings, lists, checklists, code blocks, block quotes, links, and tables.
It escapes literal text, so that it renders as it appears in the note,
and leaves out formatting that Markdown can't express, such as underlining and highlights.
`plainText()` renders the text alone, without formatting.
In both, attachments become text:
a tag becomes its text, a link card becomes its title and URL,
and an image or another file becomes a description, such as `[Image: IMG_0001.jpeg]`.

Locked notes are listed, but TopoText doesn't read their contents.

Each call opens the database read-only and closes it before returning.
TopoText never writes to the database or copies it.
To make several reads from one consistent snapshot, use `withSnapshot(_:)`.

## Development

```sh
swift test
swift format lint --strict --recursive .
```

The tests build synthetic databases, so they don't need access to your notes.

To check TopoText against your own notes, run:

```sh
swift run Validate --applescript
```

The tool prints only counts, never titles or text,
and compares its count of notes with the one from AppleScript.
Your terminal needs Full Disk Access to run it.

The [format notes](Sources/TopoText/TopoText.docc/NoteStore.md)
describe the database and where each fact comes from.

## Acknowledgments

TopoText builds on the reverse engineering in
Jon Baumann's [apple_cloud_notes_parser](https://github.com/threeplanetssoftware/apple_cloud_notes_parser),
which worked out the note format and the database schema across releases,
and Steve Dunham's [notesutils](https://github.com/dunhamsteve/notesutils),
which worked out how tables are stored.

These projects contributed specific findings:

- sweetrb's [apple-notes-mcp](https://github.com/sweetrb/apple-notes-mcp):
  how Notes marks Quick Note drafts and deleted notes,
  which contents row is current, and which run sets a paragraph's style
- mgcrea's [cupertino](https://github.com/mgcrea/cupertino):
  the title check that makes the note count match Notes,
  and contents rows that hold property lists
- sballin's [alfred-search-notes-app](https://github.com/sballin/alfred-search-notes-app):
  folders not yet fetched from iCloud, and what a search should cover
- [Obsidian Importer](https://github.com/obsidianmd/obsidian-importer):
  the creation date columns, and links between notes
- folivoraAI's [BetterTouchTool plugin for Notes](https://github.com/folivoraAI/BetterTouchToolPlugins):
  the starting number of numbered lists
- 6over3's [NotesKit](https://github.com/6over3/NotesKit):
  following indirection in tables

TopoText contains no code from these projects.

## License

MIT. See [LICENSE.md](LICENSE.md).
