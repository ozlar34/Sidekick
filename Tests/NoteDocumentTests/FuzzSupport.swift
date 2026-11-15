import Foundation

/// Environment-driven budget for the property suite. Same convention as
/// `Tests/SidekickTests/Fuzz/InvariantFuzzTests.swift`:
///   SIDEKICK_FUZZ_SEEDS=5000 SIDEKICK_FUZZ_BUDGET=120 swift test --filter NoteDocumentTests
/// SIDEKICK_FUZZ_STEPS  edits per seed (default 12)
/// SIDEKICK_FUZZ_SEED   first seed (default 1); a failure message prints its seed,
///                      re-run it with SIDEKICK_FUZZ_SEED=<n> SIDEKICK_FUZZ_SEEDS=1.
enum FuzzConfig {
    static func envInt(_ key: String, default fallback: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[key],
              let n = Int(raw), n > 0 else { return fallback }
        return n
    }
    static var seedCount: Int { envInt("SIDEKICK_FUZZ_SEEDS", default: 500) }
    static var stepsPerSeed: Int { envInt("SIDEKICK_FUZZ_STEPS", default: 12) }
    static var budgetSeconds: Int { envInt("SIDEKICK_FUZZ_BUDGET", default: 10) }
    static var firstSeed: UInt64 { UInt64(envInt("SIDEKICK_FUZZ_SEED", default: 1)) }
}

/// Deterministic xorshift64 (same generator as the editor fuzz test; `SystemRandomNumberGenerator`
/// is not seedable).
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = (seed == 0) ? 0xDEAD_BEEF_CAFE_BABE : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
