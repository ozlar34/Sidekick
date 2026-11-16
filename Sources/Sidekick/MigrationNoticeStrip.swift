import SwiftUI

/// One non-modal line at the top of the editor pane while the one-time conversion of the notes folder
/// has failed. Same look as the other strips (`OpenNoteStatusView`).
struct MigrationNoticeStrip: View {
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.yellow.opacity(0.12))
            Divider()
        }
    }
}
