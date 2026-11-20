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

Two sources describe the merge state of a note, which the first two leave out:

- Apple's own schema files, `topotext.proto` and `versioned-document.proto`,
  which the Notes web app once shipped (DUN mentions them).
  A copy is in [ElyaConrad/iCloud-API@7edb504](https://github.com/ElyaConrad/iCloud-API/tree/7edb504f1727066192178c8dd4cdb1d09742333f/resources/protobuf),
  cited as PROTO. The comments in the files are Apple's.
- [coddingtonbear/icloud-md@ffa20ef](https://github.com/coddingtonbear/icloud-md/tree/ffa20ef6378a453f0935d26f03acedf3e58540f2)
  (MIT), cited as ICMD: `proto/topotext.proto`, `src/notes/noteDocument.ts`, and `src/notes/formatReconcile.ts`.
  The project edits notes through iCloud's web interface.
  Its comments record what the Notes web app and Notes on iOS wrote in captured requests,
  and what the web app's code does.

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

- `ZIDENTIFIER`: the note's UUID, the same on every device and in `applenotes:` links to the note.
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

The messages have more fields than these, and Apple's names differ (PROTO):
`NoteStoreProto` is `Document`, with `serializationVersion` [1] and repeated `Version` [2].
ACNP's `Document` is `Version`, with `serializationVersion` [1], `minimumSupportedVersion` [2], and `data` [3];
the field that ACNP calls `version` is `minimumSupportedVersion`.
`Note` is `String`, and its other fields are the merge state, described below.
Runs also have `writingDirection` [11], `timestamp` [13] ("not used, for future compatibility" in PROTO),
and `systemAttachmentInfo` [15] (ICMD).
Paragraph styles also have `writingDirection` [3], `paragraphHints` [6], and `uuid` [9], which holds 16 bytes (ICMD).
The Notes web app writes body text with `style_type` 3 (ICMD).
Notes on macOS doesn't: the runs on macOS found no such value,
and found a paragraph style on 99 of 100 runs, half of them without a `style_type`.
So on macOS, body text has a paragraph style with no `style_type` **[inference]**.

Reading the text:

- Run lengths count UTF-16 code units (BTT; sweetrb).
- A line feed ends a paragraph, and U+2028 breaks a line within one (ACNP; OBS).
- The run that covers a paragraph's first character sets the paragraph's style (sweetrb).
  For an empty paragraph, that character is its line feed.
- Text past the last run is body text.
- Each attachment stands in the text as U+FFFC, in a run with `attachment_info`.

## Merge state

Notes combines the edits of several devices without a server that orders them.
For that, the stored document records who inserted each character and when,
and keeps deleted characters.
``Store`` doesn't read this state.
The edit engine (`StoredNote` and `NoteEditor`) keeps it and updates it.

```proto
message String {
  optional string string = 2; repeated Substring substring = 3; optional VectorTimestamp timestamp = 4;
  repeated AttributeRun attributeRun = 5; repeated Attachment attachment = 6; }
message Substring {
  optional CharID charID = 1; optional uint32 length = 2; optional CharID timestamp = 3;
  optional bool tombstone = 4; repeated uint32 child = 5; }
message CharID { optional uint32 replicaID = 1; optional uint32 clock = 2; }
message VectorTimestamp { repeated Clock clock = 1; }
message Clock { optional bytes replicaUUID = 1; repeated ReplicaClock replicaClock = 2; }
message ReplicaClock { optional uint32 clock = 1; optional uint32 subclock = 2; }
```

The schema is PROTO's. What the fields hold:

- A substring is a run of characters that one replica inserted together.
  `charID` identifies its first character, and each following character has the next clock value (DUN; ICMD).
  `length` counts UTF-16 code units (PROTO).
- The substrings are in the order of the text.
  The text is the substrings without a `tombstone`, joined (ICMD).
  A substring with a `tombstone` holds deleted characters, which stay in the document for merging (DUN; ICMD).
- The first substring has no characters and the identifier (0, 0).
  The last has no characters and the identifier (0, 0xFFFFFFFF) (ICMD).
- `child` holds indexes into the substring list (PROTO).
  They are the edges of the graph of insertions, and each one points to a later substring.
  In a document that one device wrote in order, each substring has the next one as its only child.
  After concurrent insertions at one place, a substring has several children (ICMD; DUN: "it forms a DAG").
- `timestamp` on a substring is its style timestamp (PROTO):
  the replica that last set the style of the characters, and that replica's style clock at the time.
  New text has the clock 0 (ICMD).
- The vector timestamp has an entry for each replica that edited the note, with a 16-byte UUID.
  `replicaID` is a 1-based index into the entries; 0 belongs to the first and last substrings (ICMD).
- A replica has two clocks.
  The first is its text clock: the number of UTF-16 code units that it has inserted.
  The second is its style clock: the number of its next style operation (ICMD).
  No source has seen `subclock` set.
- Table cells are `String` messages without a vector timestamp (ICMD).
- **[inference]** `ZICNOTEDATA.ZDATA` holds the same message as the field that iCloud syncs.
  ACNP and DUN read fields 2, 3, and 5 from the database, and ICMD reads the same fields from iCloud,
  but ICMD never saw a database, and ACNP and DUN never decoded the merge state.
  The run on macOS 27.0.1 supports it: every stored document had the structure that ICMD describes.

What a local edit changes (ICMD, from the Notes web app's requests and code):

- A replica that is new to the document gets an entry,
  with both clocks at the highest values among the other entries.
- Inserted text becomes a substring with the identifier (replica, text clock) and the style timestamp (replica, 0).
  The text clock advances by the length.
  If the substring before it holds the replica's newest characters, that substring grows instead.
- The new substring goes between its neighbors in the list.
  It takes the place of the edge between them,
  or, when they have no edge, takes over the children of the substring before it and becomes that one's only child.
- A substring that an edit covers in part is split.
  The second part continues the clock, keeps the style timestamp and the tombstone,
  takes over the children, and becomes the only child of the first part.
- Deleted text gets a `tombstone` of 1 and a new style timestamp, (replica, max(old clock + 8, floor)).
  A deletion counts as a style operation, and the 8 lets it win against concurrent style changes.
- A style change, such as a checklist item's state, gives the text (replica, max(old clock + 1, floor)).
- The floor is the highest style timestamp in the document,
  plus one if that timestamp would win a tie against the replica.
  Timestamps compare by clock, then by the bytes of the replica's UUID.
  The floor is never below the replica's own style clock.
- Afterwards the replica's style clock is one past the highest clock that the edit wrote.
  An edit that only made a substring grow leaves the style clock alone,
  and one that added a substring leaves it at 1 or more.

Choices that TopoText's edit engine makes where no source decides.
The counts are from the run on macOS 27.0.1 that the last section describes:

- **[inference]** A new paragraph gets a paragraph style with `style_type` for a list and none for body text,
  `writingDirection` [3] with the value of the nearest paragraph that has one,
  and `checklist` for a checklist item.
  89 of 100 stored styles had field 3; its values were not counted in that run.
  In a note where no style has field 3, new body text gets a run without a paragraph style, as 1 of 100 stored runs was.
- **[inference]** A list style on a new paragraph counts as a style operation on its text, as it does in ICMD.
- A new checklist item's `uuid` is the 16 bytes of a random UUID.
  All 959 stored identifiers were version 4 UUIDs, and no two paragraphs shared one.
- **[inference]** The engine does not write paragraph style field 9 on a new paragraph.
  28 of 100 stored styles had it, in 16 bytes, so Notes reads styles without it.
  Which paragraphs get one is not known.
- **[inference]** The engine does not write run field 13 on the run of a new paragraph.
  92 of 100 stored runs had it, so the usual run has one, but what value belongs on new text is not known.
  Text that is inserted into a paragraph takes the field with the other attributes of its neighbor,
  and a run that is split keeps fields 9 and 13 on both parts.
- The gzip header that the engine writes has the operating system byte 19, as 1,551 of 1,566 stored documents had.
  The other 15 had 3; what wrote them is not known.

Not known:

- Whether Notes on macOS accepts, from its own database, a replica that it did not create.
  ICMD's rules were checked against iCloud and other devices, not against the database.
- Where a device keeps its own replica UUID, and whether Notes checks it.
- What run field 13 and paragraph style field 9 mean.
- What value paragraph style field 3 has, and which client writes the gzip operating system byte 3.
  `Tools/Validate` counts both.

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
- `.link`: `ZALTTEXT` is the label, and `ZTOKENCONTENTIDENTIFIER` is an `applenotes:` link.
  On macOS 27.0.1 the link is `applenotes://showNote?identifier=<identifier>`, with the identifier in uppercase.
  Other sources describe `applenotes:note/<identifier>`; TopoText reads both forms.
  The link can carry the note's identifier in lowercase, and OBS uppercases it to find the note.
- `.calculateresult` and `.calculategraphexpression`: `ZALTTEXT` is the text.

Without decoding any contents, `Store.tags(for:)`, `Store.tags()`, `Store.links(from:)`,
and `Store.backlinks(to:)` read these rows (`ICInlineAttachment`, found by the entity name),
joined to their note through `COALESCE(ZNOTE1, ZNOTE)`.
They skip rows with `ZMARKEDFORDELETION`, and rows of locked notes and of Recently Deleted.
Without `ZISPASSWORDPROTECTED`, a locked note can't be told apart,
so these reads throw `unsupportedSchema` rather than read every note as unlocked.
`Store.backlinks(to:)` selects the rows whose `ZTOKENCONTENTIDENTIFIER` contains
the identifier, ignoring ASCII case, and then parses each link.

The results follow the rows, not the text.
The row of an attachment that was deleted from the text may remain until Notes removes it.
On macOS 27.0.1, a check soon after a tag was deleted from a note found no such row in the results,
and the row of a deleted link remained with `ZMARKEDFORDELETION` set, which these reads skip.
Other edits have not been checked.
If a row remains, a note can have a tag or a link that its text no longer shows,
and a tag's note count can be higher than the number of notes whose text shows the tag.
Links cover inline note links only:
a link to a note that is stored on a text run, as `applenotes:note/…` in `link`,
has no inline attachment row, so these reads don't return it.
`content(for:)` reads the text itself, so it shows only the tags and links that the text holds,
but an attachment that has no row keeps only its identifier and type,
and the tags and links in a table that can't be decoded are not shown.
Tags that differ only in case or diacritics are one tag.
The type is the one in `ZTYPEUTI1` (OBS, sweetrb).

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

A run on 2026-11-20, on macOS 27.0.1, checked the stored documents of the 1,566 unlocked notes
against what the edit engine relies on:

- Every document encodes to its stored bytes, and the stored bytes are in the canonical form,
  so a field that an edit writes has the same form as the fields around it.
- Every document has every property that the engine requires before it edits:
  one version, a vector timestamp, replicas with 16-byte UUIDs and no `subclock`,
  an end marker as the last substring, substring and run lengths that add up to the text,
  clocks within each replica's text clock, tombstones of 1, and children that come later in the list.
- The messages have only the fields that the format notes name:
  `String` 2 to 5, `Substring` 1 to 5, and `Clock` 1 and 2. `minimumSupportedVersion` is 0.
- Every replica has two clocks.
  The first substring is the empty one with the identifier (0, 0),
  and the end marker has the style timestamp (0, 0xFFFFFFFF).
- 1,334 notes have one replica, and 3 have more than ten.
- 159,914 of 232,751 substrings have a tombstone: most of what a document holds is deleted text.
  5 substrings have more than one child.
- 95,059 of 95,947 runs have a paragraph style, and 46,472 styles have a `style_type`.
  Paragraph style field 3 is on 84,446 styles and field 9, in 16 bytes, on 26,717. Run field 13 is on 88,020 runs.
- The 959 checklist runs have identifiers of 16 bytes that are version 4 UUIDs, and no identifier is in two paragraphs.
- The gzip header has no flags. Its operating system byte is 19 in 1,551 documents and 3 in 15.
- An edit that the tool applied in memory, which appended a checklist item, passed the tool's check in 1,563 documents and failed it in 3.
  The check compared whole substrings, child indexes included.
  In a document where an earlier substring points to the end marker, an insertion at the end changes that index, and the check counted it as a failure.
  Whether that explains the 3 is not confirmed; the tool now reports which check fails.

## Not read

- **Locked notes.** Their contents are encrypted with the note's password,
  or with the device passcode from iOS 16, which can't be decrypted (ACNP).
- **Shared notes.** `ZSERVERSHAREDATA` on the note or a parent folder marks a shared note (sweetrb).
- **AppleScript identifiers**, `x-coredata://<Z_METADATA.Z_UUID>/ICNote/p<Z_PK>` (ALF; BTT).

## Smart folders

A smart folder is an `ICFolder` row with a query in `ZSMARTFOLDERQUERYJSON`
(the `ZFOLDERTYPE` of smart folders differs between sources, so TopoText goes by the query).
`Store.smartFolders()` returns the folder's name, parent, account, and the query text as stored,
for every folder whose query is not NULL or empty, even if the query is not valid JSON.
One project reports a query of the form `{"entity":"note","type":{"and":[{"deleted":false}, …]}}`
(sweetrb).
On macOS 27.0.1, a smart folder with one tag rule had the query
`{"type":{"and":[{"deleted":false},{"and":[{"and":[{"deleted":false},{"and":[{"tag":"SMART"}]}]}]}]},"entity":"note"}`:
the rule sits in nested `and` clauses after the first `deleted` clause,
and the tag is in capitals, without its `#`.
Other kinds of rules have not been checked against a real database.
TopoText doesn't interpret the query or evaluate it against notes.
