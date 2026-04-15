import XCTest
@testable import Sidekick

final class HeadingExtractorTests: XCTestCase {

    func testH1AndH2Only() {
        XCTAssertEqual(HeadingExtractor.firstHeading(in: "# Hello\nbody"), "Hello")
        XCTAssertEqual(HeadingExtractor.firstHeading(in: "## Sub\nbody"), "Sub")
        XCTAssertNil(HeadingExtractor.firstHeading(in: "### H3 heading\nbody"))
        XCTAssertNil(HeadingExtractor.firstHeading(in: "#notspaced\nbody"))
        XCTAssertNil(HeadingExtractor.firstHeading(in: "body only"))
    }
}
