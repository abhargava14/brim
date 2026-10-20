import XCTest
@testable import IslandCore

final class BrimVersionTests: XCTestCase {
    func testCompareOrdersSemver() {
        XCTAssertEqual(BrimVersion.compare("0.1.0", "0.2.1"), .orderedAscending)
        XCTAssertEqual(BrimVersion.compare("0.2.1", "0.2.1"), .orderedSame)
        XCTAssertEqual(BrimVersion.compare("0.3.0", "0.2.1"), .orderedDescending)
        XCTAssertEqual(BrimVersion.compare("v0.2.1", "0.2.1"), .orderedSame)
        XCTAssertEqual(BrimVersion.compare("0.2", "0.2.0"), .orderedSame)
        XCTAssertEqual(BrimVersion.compare("0.2.0", "0.2.1"), .orderedAscending)
    }
}
