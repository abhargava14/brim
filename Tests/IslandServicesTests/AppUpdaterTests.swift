import Foundation
import XCTest
@testable import IslandServices

final class AppUpdaterTrustTests: XCTestCase {
    func testOnlyThisRepoOnGitHubIsTrusted() {
        XCTAssertNoThrow(try AppUpdater.assertTrusted(URL(string: "https://github.com/abhargava14/brim/releases/download/v0.5.4/Brim.dmg")!))
        XCTAssertNoThrow(try AppUpdater.assertTrusted(URL(string: "https://objects.githubusercontent.com/github-production-release-asset/1/abc")!))
        // Another repo on github.com, and lookalike hosts, are refused.
        XCTAssertThrowsError(try AppUpdater.assertTrusted(URL(string: "https://github.com/someone/brim-fork/releases/download/v9/Brim.dmg")!))
        XCTAssertThrowsError(try AppUpdater.assertTrusted(URL(string: "https://github.com.evil.example/abhargava14/brim/Brim.dmg")!))
        XCTAssertThrowsError(try AppUpdater.assertTrusted(URL(string: "https://evil-githubusercontent.com/Brim.dmg")!))
    }

    func testParsesShasumLinesOnly() {
        let hex = String(repeating: "a", count: 64)
        XCTAssertEqual(AppUpdater.parseSHA256("\(hex)  Brim.dmg\n"), hex)
        XCTAssertEqual(AppUpdater.parseSHA256(hex.uppercased()), hex)
        XCTAssertEqual(AppUpdater.parseSHA256("\(hex)  build/Brim.dmg"), hex)
        // Wrong length or stray characters are not a checksum.
        XCTAssertNil(AppUpdater.parseSHA256(String(repeating: "a", count: 63)))
        XCTAssertNil(AppUpdater.parseSHA256("<html>" + hex))
        XCTAssertNil(AppUpdater.parseSHA256(""))
    }
}
