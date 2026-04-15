import XCTest
@testable import Sidekick

final class SlugTests: XCTestCase {

    func testDiacriticFold() {
        XCTAssertEqual(Slug.make(from: "Café", existing: []), "cafe")
    }

    func testEmojiStripped() {
        XCTAssertEqual(Slug.make(from: "🚀 Idea", existing: []), "idea")
    }

    func testCollisionSuffix() {
        XCTAssertEqual(Slug.make(from: "Ideas", existing: ["ideas"]), "ideas-2")
        XCTAssertEqual(Slug.make(from: "Ideas", existing: ["ideas", "ideas-2"]), "ideas-3")
    }

    func testEmptyFallback() {
        XCTAssertEqual(Slug.make(from: "🚀🚀🚀", existing: []), "")
        XCTAssertEqual(Slug.make(from: "メモ", existing: []), "")
    }

    func testLengthCap() {
        let input = String(repeating: "a", count: 200)
        let result = Slug.make(from: input, existing: [])
        XCTAssertEqual(result.count, 80)
    }

    func testLocaleIndependence() {
        // Must produce lowercase dotted `i`, not `ı` (Turkish dotless-i trap).
        // RESEARCH.md Pitfall 6: use en_US_POSIX locale for lowercasing.
        XCTAssertEqual(Slug.make(from: "Istanbul", existing: []), "istanbul")
    }
}
