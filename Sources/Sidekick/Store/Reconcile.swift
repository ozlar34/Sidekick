/// Pure reconciliation: merges a disk snapshot against an existing index
/// per CONTEXT.md rules. No I/O, fully deterministic, unit-testable.
///
/// Pattern source: RESEARCH.md §Pattern 2 (Reconciliation algorithm).
///
/// Returns:
///   - `index`: the new NoteIndex (dense order, orphans dropped, external files appended)
///   - `changed`: true if `index` differs from input — caller decides whether to saveIndex
import Foundation

func reconcile(snapshot: [DiskEntry], index: NoteIndex?) -> (index: NoteIndex, changed: Bool) {
    let snapshotFilenames = Set(snapshot.map(\.filename))

    // Step 1: If index is nil, rebuild from snapshot entirely.
    if index == nil {
        // Sort by mtime descending, filename ascending as tiebreaker (Pitfall 5).
        let sorted = snapshot.sorted {
            if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
            return $0.filename < $1.filename
        }
        let entries = sorted.enumerated().map { (i, entry) in
            IndexEntry(id: UUID(), filename: entry.filename, pinned: false, order: i)
        }
        return (NoteIndex(version: 1, notes: entries), true)
    }

    let existingIndex = index!

    // Step 2: Filter out orphans (index entries whose file no longer exists on disk).
    let surviving = existingIndex.notes.filter { snapshotFilenames.contains($0.filename) }

    // Step 3: Find disk files not referenced by surviving index entries.
    let indexedFilenames = Set(surviving.map(\.filename))
    let newFilenames = snapshot.filter { !indexedFilenames.contains($0.filename) }
    // Sort new arrivals by mtime desc, filename asc (Pitfall 5).
    let sortedNew = newFilenames.sorted {
        if $0.mtime != $1.mtime { return $0.mtime > $1.mtime }
        return $0.filename < $1.filename
    }
    let newEntries = sortedNew.map { entry in
        IndexEntry(id: UUID(), filename: entry.filename, pinned: false, order: Int.max)
    }
    var merged = surviving + newEntries

    // Step 4: Renumber dense order — pinned first (preserve relative order),
    // then unpinned (preserve relative order).
    let pinned = merged.filter(\.pinned)
    let unpinned = merged.filter { !$0.pinned }
    let reordered = pinned + unpinned
    merged = reordered.enumerated().map { (i, entry) in
        var e = entry
        e.order = i
        return e
    }

    let newIndex = NoteIndex(version: 1, notes: merged)
    let changed = newIndex != existingIndex
    return (newIndex, changed)
}
