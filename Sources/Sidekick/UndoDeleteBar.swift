import SwiftUI

/// The bar under the editor after a delete: the note went to the Trash, and Undo brings it back. It goes away on
/// its own after `UndoDeleteBar.shownFor`, or when the next delete takes its place.
struct UndoDeleteBar: View {
    static let shownFor: Duration = .seconds(6)

    let deleted: DeletedNote
    let undo: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(.separatorColor)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                // A long title gives way; "moved to the Trash" always shows in full.
                Text("“\(deleted.title.isEmpty ? "Untitled" : deleted.title)”")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                Text("moved to the Trash")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                Button("Undo", action: undo)
                    .help("Undo Delete (⌘Z)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor))
        }
    }
}

/// Brings the last deleted note back and selects it. One path for the bar's Undo button and for ⌘Z.
@MainActor
func undoLastDelete(store: NoteStore, panelState: PanelState) {
    Task { @MainActor in
        do {
            if let id = try await store.undoDelete() { panelState.selectedNoteID = id }
        } catch {
            NSLog("[Sidekick] undo delete failed: \(error.localizedDescription)")
        }
    }
}
