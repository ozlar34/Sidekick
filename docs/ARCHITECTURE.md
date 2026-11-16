# Architecture

Sidekick keeps notes as plain `.md` files in one folder. Four modules sit between the file and the screen. Each owns one thing and talks to its neighbours through a small interface.

```
disk  <->  note store  <->  open note  <->  editor view  <->  note document
(.md)      NoteStore        OpenNote        NoteTextView       NoteDocument
```

## The modules

**Note document** (`Sources/NoteDocument`, its own SwiftPM target, Foundation only). The in-memory form of one note: markdown in, edits, markdown out. `NoteDocument(markdown:)` reads the text into `Block`s (each a `BlockKind` plus `Run`s: text with marks), `apply(_ edit: Edit)` changes it, `markdown()` writes it. It owns the fidelity rules: a block equal to its state at load is written from its original bytes, an edited block keeps its remembered literal prefix (`*` bullets, `1)` numbers, `__` bold, CRLF), and generated text is escaped so that it reads back equal. It knows nothing about AppKit, files or timing. `TypedMarkdown.convert` holds the rule table for typed triggers (`- `, `**x**`, ...).

**Editor view** (`Sources/Sidekick/NewEditor`). `NoteTextView` is the one text view; `NoteEditorView` hosts it in SwiftUI. It shows a note document as text without markers: `NoteBuffer.attributed(for:)` turns blocks into an attributed string (block kind and marks as attributes, a URL pill as one attachment character), `NoteTextEngine` and `NoteLayoutManager` draw bullets, boxes, numbers, dividers and pills. Key, mouse, clipboard, format and link handling live in the `NoteTextView+*.swift` extensions; format commands are `NoteFormatCommand` handled by `NoteTextView.perform(_:)`. After each edit `NoteContent.storageDidChange()` compares the buffer's paragraphs (`NoteBuffer.paragraphs(in:tailKind:)`) with the last synced ones and applies the difference to the note document as `Edit`s. The text view never touches a file.

**Open note** (`OpenNote.swift`). One per note the user has worked on in this session. It owns the note's `NoteContent` (text storage, `UndoManager`, note document), the disk baseline (the exact bytes it last read or wrote), the dirty, conflict and save-failed state, and the save debounce (`SaveScheduling`, `TaskSaveScheduler`, 500 ms). It is the only writer of that note's content. It reads the file itself (`loadFromDisk`), saves through the `Save` closure the store gives it, and reacts to `externalChange()` (reload silently, or raise the conflict banner when there are unsaved edits). A file that is not valid UTF-8 or cannot be read puts it in the `.unreadable` state: read-only, no save path.

**Note store** (`Sources/Sidekick/Store`). `NoteStore` is the main-actor owner of the notes folder: the list of `Note`s, the open notes (`openNote(_:)`), create, delete, pin, rename, folder moves and external-change handling. All disk work goes through `IOActor` (read, create, atomic write with a baseline check, trash, scan, order file). `FolderWatcher` reports changed files, `OrderFile` keeps pins and manual order beside the notes, `TitleRules` turns titles into file names, and `Migration` converts the old slug-and-index layout once (with a verified backup first).

## Seams: who calls what

- **View to document.** `NoteContent.storageDidChange()` calls `NoteDocument.apply(_:)` and then `onEdit`. The document is read back with `NoteDocument.markdown()`. Nothing else crosses this seam.
- **Document to open note.** `OpenNote` creates `NoteContent` and listens to its `onEdit`. It asks `content.markdown` when it saves and `content.reload(markdown:)` when it loads.
- **Open note to store.** `NoteStore.openNote(_:)` builds the `OpenNote` with a save closure that calls `NoteStore.save(_:title:body:baseline:)`. `NoteStore` calls back with `OpenNote.externalChange()` and `reload()`, and sets `fileURL` after a rename.
- **Store to disk.** Only `IOActor` and `FileOps` touch files.
- **SwiftUI shell.** `EditorPaneView` shows the title field, `FormattingToolbarView`, `NoteEditorView` and the banners. `EditorController` carries the text view and the toolbar state between them. `AppDelegate`'s Format menu actions call `NoteTextView.perform(_:)` on the panel's editor.

## Bytes from disk to screen and back

Disk to screen: `OpenNote.loadFromDisk` reads the file (`Data`, kept as the baseline) -> `NoteContent.reload(markdown:)` -> `NoteDocument(markdown:)` -> `NoteBuffer.attributed(for:)` -> the `NSTextStorage` of the `NoteContent` -> `NoteTextView.attach(_:)` shows it.

Screen to disk: a key press in `NoteTextView` edits the storage -> `NoteContent.storageDidChange()` updates the `NoteDocument` -> `OpenNote` becomes dirty and schedules a save -> after the debounce `OpenNote` calls `NoteStore.save(_:title:body:baseline:)` with `NoteDocument.markdown()` -> `IOActor.save` checks that the file still holds the baseline bytes (otherwise `NoteStoreError.conflict`, nothing is written) and writes atomically. Panel dismiss, note switch and quit flush pending saves (`NoteStore.flushOpenNotes()`).

External changes: `FolderWatcher` -> `NoteStore.handleExternalChange(files:)` -> `OpenNote.externalChange()`.

## Tests

`Tests/NoteDocumentTests` covers the note document (including seeded generated notes: `SIDEKICK_FUZZ_SEEDS`, `SIDEKICK_FUZZ_STEPS`). `Tests/SidekickTests/NewEditor` drives the editor view in a real window with real key events (`NewEditorHost`), `OpenNoteTests` covers the open note, and the store tests (`NoteStoreIntegrationTests`, `FilesAreTruthTests`, `SafeSavesTests`, `MigrationTests`, `StoreInterleavingTests`) cover the note store.

## Debug harness

`Sources/Sidekick/Debug` is compiled into debug builds only (`#if DEBUG`); a release build contains none of it. See the README.
