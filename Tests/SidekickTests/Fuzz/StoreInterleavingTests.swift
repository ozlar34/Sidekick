import XCTest
@testable import Sidekick

/// Seam 3: folder operations issued without waiting for each other must give the result of some
/// serial order. Each seed builds a random operation list, submits every operation at once, and
/// compares the final folder with the same list run one by one (submission order is the serial
/// order the store must pick). No sleeps and no clock: the operations are queued before any of them
/// runs, so a seed gives the same outcome on every run.
///
///   SIDEKICK_FUZZ_SEEDS   seeds to run (default 25)
///   SIDEKICK_FUZZ_BUDGET  wall-clock seconds for the whole test (default 60)
///   SIDEKICK_FUZZ_SEED    first seed (default 1); failures print their seed
@MainActor
final class StoreInterleavingTests: XCTestCase {

    private enum Op: CustomStringConvertible {
        case create
        case update(slot: Int, title: String, body: String)
        case delete(slot: Int)
        case pin(slot: Int, pinned: Bool)
        case reorder([Int])
        case reload

        var description: String {
            switch self {
            case .create: return "create"
            case .update(let s, let t, let b): return "update(\(s), \(t.debugDescription), \(b.debugDescription))"
            case .delete(let s): return "delete(\(s))"
            case .pin(let s, let p): return "pin(\(s), \(p))"
            case .reorder(let o): return "reorder(\(o))"
            case .reload: return "reload"
            }
        }
    }

    private struct Rng {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
    }

    private static let slots = 3
    // Few titles on purpose: equal titles force the collision path while another operation runs.
    // Case variants and a path character: renames that differ only by case, and a replaced character.
    private static let titles = ["Alpha", "Beta", "alpha", "Gamma", "", "A/B", "Alpha"]

    private func makeOps(seed: UInt64) -> [Op] {
        var rng = Rng(state: seed &* 0x9E3779B97F4A7C15 | 1)
        return (0..<(6 + rng.next(8))).map { i in
            switch rng.next(7) {
            case 0: return .create
            case 1, 2: return .update(slot: rng.next(Self.slots), title: Self.titles[rng.next(Self.titles.count)],
                                      body: "body \(seed)-\(i)\n")
            case 3: return .delete(slot: rng.next(Self.slots))
            case 4: return .pin(slot: rng.next(Self.slots), pinned: rng.next(2) == 0)
            case 5: return .reorder((0..<Self.slots).map { $0 }.sorted { _, _ in rng.next(2) == 0 })
            default: return .reload
            }
        }
    }

    private func makeStore(_ folder: TempFolder) async throws -> (NoteStore, [UUID]) {
        let store = try NoteStore(folder: folder.url, startWatcherImmediately: false,
                                  trash: { try FileManager.default.removeItem(at: $0) })
        var ids: [UUID] = []
        for i in 0..<Self.slots {
            let n = try await store.create()
            try await store.update(n.id, title: "", body: "seed \(i)\n")
            ids.append(n.id)
        }
        return (store, ids)
    }

    /// Runs one operation and says how it ended.
    private func run(_ op: Op, _ store: NoteStore, _ ids: [UUID]) async -> String {
        do {
            switch op {
            case .create: _ = try await store.create()
            case .update(let s, let t, let b): try await store.update(ids[s], title: t, body: b)
            case .delete(let s): try await store.delete(ids[s])
            case .pin(let s, let p): try await store.setPinned(ids[s], p)
            case .reorder(let o): try await store.reorder(o.map { ids[$0] })
            case .reload: await store.reload()
            }
            return "ok"
        } catch {
            return "failed"
        }
    }

    /// What the user could observe: the list in order, the files with their bytes, and the order
    /// file. Names are deterministic now (the title, or "Untitled", with a number suffix on a collision),
    /// so they are compared as they are.
    private func state(_ store: NoteStore, _ folder: TempFolder) throws -> String {
        let list = store.notes.map { "\($0.filename)|\($0.title)|\($0.body.debugDescription)|\($0.pinned)|\($0.order)" }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
            .filter { $0.hasSuffix(".md") }
            .map { "\($0)=\(String(decoding: try Data(contentsOf: folder.url.appendingPathComponent($0)), as: UTF8.self).debugDescription)" }
            .sorted()
        let order = (try? Data(contentsOf: folder.url.appendingPathComponent(OrderFile.filename)))
            .flatMap(OrderFile.decode).map { "pinned=\($0.pinned) order=\($0.order)" } ?? "no order file"
        return (list + ["--"] + files + ["--", order]).joined(separator: "\n")
    }

    func testInterleavedOperationsEqualASerialOrder() async throws {
        let env = ProcessInfo.processInfo.environment
        let seeds = Int(env["SIDEKICK_FUZZ_SEEDS"] ?? "") ?? 25
        let budget = Double(env["SIDEKICK_FUZZ_BUDGET"] ?? "") ?? 60
        let first = UInt64(env["SIDEKICK_FUZZ_SEED"] ?? "") ?? 1
        let start = Date()
        var failures: [String] = []

        for seed in first..<(first + UInt64(seeds)) {
            if Date().timeIntervalSince(start) > budget { break }
            let ops = makeOps(seed: seed)

            let serialFolder = TempFolder()
            let (serial, serialIDs) = try await makeStore(serialFolder)
            var serialResults: [String] = []
            for op in ops { serialResults.append(await run(op, serial, serialIDs)) }
            await serial.reload()

            let racedFolder = TempFolder()
            let (raced, racedIDs) = try await makeStore(racedFolder)
            let tasks = ops.map { op in Task { @MainActor in await self.run(op, raced, racedIDs) } }
            var racedResults: [String] = []
            for t in tasks { racedResults.append(await t.value) }
            await raced.reload()

            let want = try state(serial, serialFolder), got = try state(raced, racedFolder)
            if want != got || serialResults != racedResults {
                failures.append("seed \(seed): ops \(ops)\n  results serial \(serialResults) vs raced \(racedResults)\n  serial:\n\(want)\n  raced:\n\(got)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) seed(s) differ from the serial order. First:\n\(failures.first ?? "")")
    }
}
