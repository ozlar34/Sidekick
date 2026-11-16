# Status

**Live — maintenance mode** (as of 2026-11-16)

## How work happens now

- New features when wanted, bugfixes when noticed, all ad hoc.
- No GSD, no milestones, no phases, no roadmap.

## Design

- Notes are plain `.md` files in one folder; the files are the truth (no database, no index file).
- One editor: a rich-text view over a note document that keeps the file's own spelling for every block you did not edit. Four modules (note document, editor view, open note, note store): see `docs/ARCHITECTURE.md`.
- Saves check the file against the bytes the app last read, so an outside change is never overwritten silently.
- The debug harness (`Sources/Sidekick/Debug`) exists in debug builds only.

## History

- Last GSD milestone: v1.4 (hr-optimization). GSD planning history (v1.0–v1.4): `.archive/gsd-planning/` (local-only, gitignored).
- 2026-11: foundations redesign. The markdown-in-buffer editor was replaced by the note-document editor; the old editor and its switch were removed.
