# The Notes database

This article records the facts about the Notes database that TopoText relies on,
and where each fact comes from.
Read it before you change a query or a decoder.

Apple doesn't document this format.
The facts come from open-source projects that read it,
from TopoText's synthetic tests,
and from one check against a real database, described at the end.
Facts marked **[conflict]** differ between sources;
facts marked **[inference]** follow from the sources but no source states them.

## Sources

The earliest and most original sources are these two projects:

- Jon Baumann's [apple_cloud_notes_parser](https://github.com/threeplanetssoftware/apple_cloud_notes_parser)
  (Ciofeca Forensics, first commit 2017-10-09),
  cited as ACNP at [`4754a2b`](https://github.com/threeplanetssoftware/apple_cloud_notes_parser/tree/4754a2b62686570cca46690d101079e80cf6ae66):
  the note protocol buffer and the database schema across releases.
- Steve Dunham's [notesutils](https://github.com/dunhamsteve/notesutils)
  (first commit 2017-12-17, public domain),
  cited as DUN at [`582e569`](https://github.com/dunhamsteve/notesutils/blob/582e569c9d0a6b398e91099260eaf761366a5f68/notes.md):
  the table CRDT, including how deleted and repeated rows and columns are left out.

Later projects confirm these facts on newer releases and add a few:

| Short name | Repository and commit |
|---|---|
| OBS | [obsidianmd/obsidian-importer@9e574b8](https://github.com/obsidianmd/obsidian-importer/tree/9e574b819ddfe3179837143e9db5e79140463924/src/formats) |
| NK | [6over3/NotesKit@73d08c9](https://github.com/6over3/NotesKit/tree/73d08c977ec82026c34cc99b62b9b600b459839c) (AGPL-3.0; facts only) |
| BTT | [folivoraAI/BetterTouchToolPlugins@9f9f306](https://github.com/folivoraAI/BetterTouchToolPlugins/blob/9f9f306136fbd9e7a7f910c91b50c1c317bee7c6/plugins/official/launcher-apple-notes/AppleNotesLauncherPlugin.swift) |
| ALF | [sballin/alfred-search-notes-app@959049b](https://github.com/sballin/alfred-search-notes-app/blob/959049bf0525c8bf62cd4eb02cc189ccf66c88e4/search_notes/main.go) |
| sweetrb | [sweetrb/apple-notes-mcp@5880180](https://github.com/sweetrb/apple-notes-mcp/blob/58801802ef34b509a486deefbcdf613ab3d4fbe8/TECHNICAL_NOTES.md) (checked against macOS 27.2) |
| cupertino | [mgcrea/cupertino@6054516](https://github.com/mgcrea/cupertino/blob/605451638e06473d762ae0e64bced141b83f2609/docs/notes.md) (measured on macOS 26.6) |

TopoText doesn't contain code from any of these projects.

## Files

The Notes folder is `~/Library/Group Containers/group.com.apple.notes`.
It holds the Core Data database `NoteStore.sqlite`
and, because the database uses write-ahead logging, `NoteStore.sqlite-wal` and `NoteStore.sqlite-shm`.
Recent edits can be only in the log, so a reader must be able to read all three files.

TopoText opens the database read-only, in place, with a busy timeout of one second.
If the database can't be opened and there is no `-wal` file,
TopoText opens it again with `immutable=1`,
which reads the main file alone.
This happens when the folder is read-only and SQLite can't create the `-shm` file;
without a log, every record is in the main file.
The system SQLite keeps the `-wal` and `-shm` files after the last connection closes,
so on a Mac that runs Notes the files are normally present.

## Entities and rows

Accounts, folders, notes, and attachments are rows of one table, `ZICCLOUDSYNCINGOBJECT`,
told apart by the entity number in `Z_ENT`.
The numbers differ between databases (sweetrb),
so TopoText looks them up by name in `Z_PRIMARYKEY`:
`ICAccount`, `ICFolder`, `ICNote`, `ICAttachment`, `ICInlineAttachment`, and `ICMedia`.

Columns that several entities define get numbered suffixes,
such as `ZTITLE1` for note titles and `ZTITLE2` for folder names,
and columns move and disappear between releases (ACNP).
TopoText reads the columns of the table with `pragma_table_info`
and puts NULL in place of a column that the table lacks.

Timestamps are Core Data seconds since 2001-01-01 UTC.

`Z_METADATA.Z_UUID` identifies the database.
TopoText puts it in cursors, so that a cursor from another database is rejected.

## Notes

A note row is listed only when all of these are true:

- `Z_ENT` is the `ICNote` entity.
- `ZTITLE1` is not NULL.
  On macOS 26.6, `ICNote` rows outnumbered the notes that Apple Events reported,
  and this condition made the counts equal (cupertino).
- `ZFOLDER` is not NULL.
  Drafts of Quick Notes (`ZISSYSTEMPAPER = 1`) have no folder, and Notes doesn't show them (sweetrb).
- `ZMARKEDFORDELETION` is not 1.
  These rows are already deleted and wait for the deletion to sync (sweetrb).
  **[conflict]** NK and others say that the column marks notes in Recently Deleted;
  sweetrb's check on macOS 27 found that Recently Deleted is a folder instead.

Columns:

- `ZIDENTIFIER`: the note's UUID, the same on every device and in `applenotes:note/<identifier>` links.
- `ZTITLE1`: the title.
- `ZSNIPPET`, then `ZWIDGETSNIPPET` (iOS 17 and later): the preview.
  cupertino found `ZWIDGETSNIPPET` on more notes than `ZSNIPPET`.
- `COALESCE(ZCREATIONDATE3, ZCREATIONDATE2, ZCREATIONDATE1)`: the creation date (OBS).
  ACNP reads `ZCREATIONDATE3` from iOS 15; **[conflict]** cupertino reads `ZCREATIONDATE1` on macOS 26.6.
- `ZMODIFICATIONDATE1`: the modification date.
- `ZISPINNED` and `ZISPASSWORDPROTECTED`.

A locked note's stored preview can still hold text from before the note was locked **[inference]**,
so TopoText never returns it, and search matches a locked note by its title alone.

## Folders and accounts

- `ZTITLE2`: the folder name. Some default and Recently Deleted folders have none.
- `ZPARENT`: the folder that this one is nested in.
- `ZOWNER`: the account. ACNP prefers it to the `ZACCOUNTn` columns, which move between releases.
- **Recently Deleted** is a folder with `ZFOLDERTYPE = 1`
  or an identifier that starts with `TrashFolder` (sweetrb).
- **Smart folders** have a non-empty `ZSMARTFOLDERQUERYJSON`.
  **[conflict]** Their `ZFOLDERTYPE` is 3 in OBS and 2 in NK, so TopoText checks the query instead.
- Folders with `ZNEEDSINITIALFETCHFROMCLOUD = 1` haven't been fetched yet, and are left out (ALF).
- The account's `ZIDENTIFIER` names its folder of files, `Accounts/<identifier>`.
  On My Mac uses `LocalAccount`.

## Note contents

`ZICNOTEDATA.ZDATA` holds the contents, gzip-compressed (RFC 1952, not zlib) (ACNP).
An edit can leave an older row for the same note, so TopoText reads the newest,
`WHERE ZNOTE = ? ORDER BY Z_PK DESC LIMIT 1` (sweetrb).
Some rows hold property lists instead (cupertino),
so data without the gzip signature is unrecognized rather than damaged.

Foundation's zlib algorithm reads raw deflate data,
so TopoText parses the gzip header and its optional fields itself,
and checks the CRC-32 and size in the trailer.

The decompressed data is a protocol buffer (ACNP `proto/notestore.proto`):

```proto
message NoteStoreProto { required Document document = 2; }
message Document { required int32 version = 2; required Note note = 3; }
message Note { required string note_text = 2; repeated AttributeRun attribute_run = 5; }
message AttributeRun {
  required int32 length = 1; optional ParagraphStyle paragraph_style = 2; optional Font font = 3;
  optional int32 font_weight = 5; optional int32 underlined = 6; optional int32 strikethrough = 7;
  optional int32 superscript = 8; optional string link = 9; optional Color color = 10;
  optional AttachmentInfo attachment_info = 12; optional int32 emphasis_style = 14; }
message ParagraphStyle {
  optional int32 style_type = 1 [default = -1]; optional int32 alignment = 2;
  optional int32 indent_amount = 4; optional Checklist checklist = 5; optional int32 block_quote = 8; }
message Checklist { required bytes uuid = 1; required int32 done = 2; }
message Color { required float red = 1; required float green = 2; required float blue = 3; required float alpha = 4; }
message AttachmentInfo { optional string attachment_identifier = 1; optional string type_uti = 2; }
```

Values:

- `style_type`: -1 body, 0 title, 1 heading, 2 subheading, 4 monospaced,
  100 bulleted list, 101 dashed list, 102 numbered list, 103 checklist.
- `alignment`: 0 left, 1 center, 2 right, 3 justified.
- `font_weight`: 1 bold, 2 italic, 3 both.
- `superscript`: positive for superscript, negative for subscript.
- `emphasis_style`: the highlight color, 1 purple, 2 pink, 3 orange, 4 mint, 5 blue.
- `ParagraphStyle` field 7 is the starting number of a numbered list (BTT; sweetrb).

Reading the text:

- Run lengths count UTF-16 code units (BTT; sweetrb).
- A line feed ends a paragraph, and U+2028 breaks a line within one (ACNP; OBS).
- The run that covers a paragraph's first character sets the paragraph's style (sweetrb).
  For an empty paragraph, that character is its line feed.
- Text past the last run is body text.
- Each attachment stands in the text as U+FFFC, in a run with `attachment_info`.

## Attachments

TopoText finds each attachment's row by `ZIDENTIFIER`, from the run's `attachment_identifier` (ACNP).
If no row has the identifier, the attachment was deleted (ACNP),
and only the identifier and the run's `type_uti` are known.

The type is `COALESCE(ZTYPEUTI1, ZTYPEUTI)`:
inline attachments use `ZTYPEUTI1`, and other attachments use `ZTYPEUTI`.

Inline attachments (`ICInlineAttachment`) have types that start with
`com.apple.notes.inlinetextattachment.`:

- `.hashtag`: `ZALTTEXT` is the tag, such as `#groceries`.
- `.mention`: `ZALTTEXT` is the text, and `ZTOKENCONTENTIDENTIFIER` identifies the participant.
- `.link`: `ZALTTEXT` is the label, and `ZTOKENCONTENTIDENTIFIER` is an `applenotes:note/…` link.
  The link can carry the note's identifier in lowercase, and OBS uppercases it to find the note.
- `.calculateresult` and `.calculategraphexpression`: `ZALTTEXT` is the text.

Other attachments (`ICAttachment`):

- `ZTITLE` (then `ZUSERTITLE`), `ZURLSTRING`, `ZSUMMARY`,
  `ZOCRSUMMARY` (text in images and scans), and `ZHANDWRITINGSUMMARY` (text in drawings) (ACNP; ALF).
- `ZMEDIA` points to an `ICMedia` row with `ZIDENTIFIER`, `ZFILENAME`, and `ZGENERATION1` or `ZGENERATION`.
- `public.url` is a link card with `ZURLSTRING` and `ZTITLE` (sweetrb).
- Drawings are `com.apple.drawing`, `com.apple.drawing.2`, `com.apple.paper`, and `com.apple.notes.sketch`;
  scanned documents are `com.apple.notes.gallery`, `com.apple.paper.doc.scan`, and `com.apple.paper.doc.pdf` (ACNP; OBS).
  Other kinds come from the type's conformance, such as to `public.image`.

### Files

Paths are relative to the Notes folder, below `Accounts/<account identifier>/`,
or at the top of the folder in older stores and for On My Mac (ACNP; OBS):

- Media: `Media/<media identifier>/<generation>/<file name>`,
  without the generation folder before iOS 17.
- Drawings: `FallbackImages/<attachment identifier>/<ZFALLBACKIMAGEGENERATION>/FallbackImage.png`,
  or `FallbackImages/<attachment identifier>.jpg` in older stores.
- Scanned documents: `FallbackPDFs/<attachment identifier>/<ZFALLBACKPDFGENERATION>/FallbackPDF.pdf`,
  or `FallbackPDFs/<attachment identifier>.pdf` in older stores.

TopoText finds the account through the attachment's note (`ZNOTE`), its folder, and the folder's `ZOWNER`.
It returns the first candidate that is a regular file inside the Notes folder.
The files of locked notes are encrypted, with an `.encrypted` suffix (ACNP), and TopoText doesn't return them.

TopoText doesn't read previews (`Previews/`), the pages of scanned galleries,
or the transcripts of audio recordings.

## Tables

A table attachment (`com.apple.notes.table`) stores its cells in `ZMERGEABLEDATA1`,
or `ZMERGEABLEDATA` before iOS 13 (ACNP), as gzip-compressed `MergableDataProto`.
The data is the state of a CRDT (DUN):

```proto
message MergableDataProto { required MergableDataObject mergable_data_object = 2; }
message MergableDataObject { required int32 version = 2; required MergeableDataObjectData mergeable_data_object_data = 3; }
message MergeableDataObjectData {
  repeated MergeableDataObjectEntry mergeable_data_object_entry = 3; repeated string mergeable_data_object_key_item = 4;
  repeated string mergeable_data_object_type_item = 5; repeated bytes mergeable_data_object_uuid_item = 6; }
message MergeableDataObjectEntry {
  required RegisterLatest register_latest = 1; optional Dictionary dictionary = 6;
  optional Note note = 10; optional MergeableDataObjectMap custom_map = 13; optional OrderedSet ordered_set = 16; }
message ObjectID { required uint64 unsigned_integer_value = 2; required string string_value = 4; required int32 object_index = 6; }
message RegisterLatest { required ObjectID contents = 2; }
message Dictionary { repeated DictionaryElement element = 1; }
message DictionaryElement { required ObjectID key = 1; required ObjectID value = 2; }
message MergeableDataObjectMap { required int32 type = 1; repeated MapEntry map_entry = 3; }
message MapEntry { required int32 key = 1; required ObjectID value = 2; }
message OrderedSet { required OrderedSetOrdering ordering = 1; required Dictionary elements = 2; }
message OrderedSetOrdering { required OrderedSetOrderingArray array = 1; required Dictionary contents = 2; }
message OrderedSetOrderingArray { required Note contents = 1; repeated OrderedSetOrderingArrayAttachment attachment = 2; }
message OrderedSetOrderingArrayAttachment { required int32 index = 1; required bytes uuid = 2; }
```

Decoding:

1. Objects refer to one another by `object_index` into the entries.
   Key names, type names, and UUIDs are in the side lists (fields 4, 5, and 6).
2. The table is the object whose `custom_map.type` names `com.apple.notes.ICTable`.
   Its map entries, keyed by name, point to `crRows`, `crColumns`, and `cellColumns`.
3. A UUID reference is an `ObjectID` that points to a `com.apple.CRDT.NSUUID` map,
   whose `UUIDIndex` entry holds an index into the UUID list.
4. `crRows` and `crColumns` are ordered sets.
   `ordering.array.attachment` lists UUIDs by position,
   and `ordering.contents` maps each one to the UUID that cells use.
   Positions whose UUID is not among `elements` were deleted,
   and a UUID that appears twice takes its first position,
   as Notes does after conflicting moves (DUN, `notes2html`).
   **[inference]** ACNP and OBS count every position, so they can show extra empty rows and columns.
5. `cellColumns` maps each column UUID to a dictionary from each row UUID to a cell,
   whose `note` (field 10) is a `Note` message, read as note contents are.
   Cells can contain attachments, including tables (ACNP).
6. A reference can point to a `register_latest` that points to another object (NK);
   TopoText follows up to eight such steps.
7. A `CRTableColumnDirectionRightToLeft` string among the objects reverses the columns (sweetrb).

When a table can't be decoded, `ZSUMMARY` still has its plain text (ALF).
TopoText decodes tables nested four deep and leaves deeper tables undecoded.
It also leaves undecoded a table inside itself, which damaged data could hold.

## Search

No source finds body text in SQL; every one decompresses and decodes each note.
TopoText reads candidate notes newest first, up to the request's scan limit,
and matches the query against the title, the preview, and the decoded text,
without regard to case or diacritics.
The decoded text includes the text of inline attachments, table cells (or a table's summary),
link cards, attachment titles and file names,
and the text that Notes recognizes in images and handwriting, as ALF does.

## Checked against a real database

`Tools/Validate` reads a real database and prints only counts.
A run on macOS 27 found the following:

- The notes that TopoText lists are the notes that AppleScript counts,
  which include the notes in Recently Deleted.
- Every unlocked note decodes, and every table decodes.
- In every note, the run lengths add up to the length of the text in UTF-16 code units.
- No note has a `style_type`, `font_weight`, or `emphasis_style` value outside the lists above.
  The `alignment` values were 0, 1, and 3.
- Runs also have fields 3, 11, and 13, and paragraph styles have fields 3 and 9,
  which TopoText doesn't read.
- Some note text has U+FFFC in runs without `attachment_info`.
  Notes shows no attachment there, so TopoText keeps the character as text.
- The files of drawings, images, PDFs, and `com.apple.paper.doc.scan` documents are where this document says.
  `com.apple.notes.gallery` attachments have no file of their own; their pages are separate images.
- `ZTITLE1` is not always the first line.
  When the first line is empty, it is the first line with text,
  and when the first line has an inline attachment, it includes the attachment's text.
  Other titles don't appear in the text at all, for reasons that are not known yet.
  TopoText returns `ZTITLE1` as the title.

## Not read

- **Locked notes.** Their contents are encrypted with the note's password,
  or with the device passcode from iOS 16, which can't be decrypted (ACNP).
- **Shared notes.** `ZSERVERSHAREDATA` on the note or a parent folder marks a shared note (sweetrb).
- **Smart folder queries** in `ZSMARTFOLDERQUERYJSON`.
- **AppleScript identifiers**, `x-coredata://<Z_METADATA.Z_UUID>/ICNote/p<Z_PK>` (ALF; BTT).
