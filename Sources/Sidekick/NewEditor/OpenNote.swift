import Foundation

/// Decides when a scheduled save fires. The app uses `TaskSaveScheduler` (500 ms debounce); tests
/// use a scheduler that fires on command, so no test waits on a clock.
@MainActor
protocol SaveScheduling: AnyObject {
    /// Replaces any scheduled work with `work`.
    func schedule(_ work: @escaping @MainActor () -> Void)
    func cancel()
}

/// Debounce: the work runs once `interval` has passed without another `schedule`.
@MainActor
final class TaskSaveScheduler: SaveScheduling {
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    init(interval: TimeInterval = 0.5) { self.interval = interval }

    func schedule(_ work: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { [interval] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            work()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

/// One note the user works on: its text and undo history (`content`), its disk baseline, its dirty
/// state, its save debounce and its failure state. It is the only writer of this note's content.
/// The view layer hosts `content` in the text view and observes the published state; the note text
/// never travels through view state.
///
/// A file that cannot be read gives the `.unreadable` state: the text view is read-only and there is
/// no save path.
@MainActor
final class OpenNote: ObservableObject {
    enum State: Equatable {
        case editable
        case unreadable(message: String)
    }

    /// Writes title and markdown to the notes folder (the store's `update`).
    typealias Save = (_ title: String, _ markdown: String) async throws -> Void

    let id: UUID
    let content: NoteContent
    /// Where the file lives. The store updates it when a title change renames the file.
    var fileURL: URL

    @Published private(set) var state: State = .editable
    /// True while the text or title differs from what is on disk.
    @Published private(set) var isDirty = false
    /// True after a save failed, until a save succeeds. The note stays dirty meanwhile.
    @Published private(set) var saveFailed = false

    /// Called when `isDirty` changes (the panel's unsaved dot).
    var onDirtyChange: ((Bool) -> Void)?
    /// Called when a save fails (the "Could not save" message).
    var onSaveFailure: (() -> Void)?

    private(set) var title: String
    /// Disk baseline: what the app last read from or wrote to the file.
    private var baselineMarkdown = ""
    private var baselineTitle: String
    private let scheduler: SaveScheduling
    private let save: Save
    private var inFlight: Task<Void, Never>?

    init(id: UUID, title: String, fileURL: URL, scheduler: SaveScheduling? = nil, save: @escaping Save) {
        self.id = id
        self.title = title
        self.baselineTitle = title
        self.fileURL = fileURL
        self.scheduler = scheduler ?? TaskSaveScheduler()
        self.save = save
        self.content = NoteContent()
        content.onEdit = { [weak self] _ in self?.contentDidChange() }
        loadFromDisk()
    }

    var markdown: String { content.markdown }

    // MARK: Reading

    /// Reloads the note from its file (external change, explicit reload). Drops the undo history.
    func reload() {
        scheduler.cancel()
        loadFromDisk()
    }

    private func loadFromDisk() {
        do {
            let data = try Data(contentsOf: fileURL)
            guard let text = String(data: data, encoding: .utf8) else {
                enterUnreadable("\u{201C}\(fileURL.lastPathComponent)\u{201D} is not valid UTF-8 text, so Sidekick shows it read-only and never changes it.")
                return
            }
            baselineMarkdown = text
            baselineTitle = title
            content.isEditable = true
            content.reload(markdown: text)
            state = .editable
            setDirty(false)
        } catch {
            enterUnreadable("\u{201C}\(fileURL.lastPathComponent)\u{201D} could not be read (\(error.localizedDescription)), so Sidekick shows it read-only and never changes it.")
        }
    }

    private func enterUnreadable(_ message: String) {
        content.isEditable = false
        content.reload(markdown: "")
        state = .unreadable(message: message)
        setDirty(false)
    }

    // MARK: Editing and saving

    func setTitle(_ newTitle: String) {
        guard case .editable = state, newTitle != title else { return }
        title = newTitle
        stateChanged()
    }

    private func contentDidChange() {
        guard case .editable = state else { return }
        stateChanged()
    }

    /// Dirty follows the baseline: back at the baseline means no save is scheduled.
    private func stateChanged() {
        if markdown == baselineMarkdown && title == baselineTitle {
            scheduler.cancel()
            setDirty(false)
        } else {
            setDirty(true)
            scheduler.schedule { [weak self] in
                guard let self else { return }
                Task { await self.saveNow() }
            }
        }
    }

    /// Saves now (note switch, panel dismiss, quit) and returns when the write has finished,
    /// including a save that was already running.
    func flush() async {
        scheduler.cancel()
        await saveNow()
    }

    func retrySave() async { await flush() }

    private func saveNow() async {
        let previous = inFlight
        let run = Task { @MainActor in
            await previous?.value
            await self.writeIfNeeded()
        }
        inFlight = run
        await run.value
    }

    private func writeIfNeeded() async {
        guard case .editable = state else { return }
        let text = markdown, currentTitle = title
        guard text != baselineMarkdown || currentTitle != baselineTitle else { return }
        do {
            try await save(currentTitle, text)
            baselineMarkdown = text
            baselineTitle = currentTitle
            saveFailed = false
        } catch {
            NSLog("[Sidekick] save failed for \(fileURL.lastPathComponent): \(error.localizedDescription)")
            saveFailed = true
            onSaveFailure?()
            return
        }
        // Typing during the write: still dirty, and its own save is already scheduled.
        setDirty(markdown != baselineMarkdown || title != baselineTitle)
    }

    private func setDirty(_ dirty: Bool) {
        guard isDirty != dirty else { return }
        isDirty = dirty
        onDirtyChange?(dirty)
    }
}
