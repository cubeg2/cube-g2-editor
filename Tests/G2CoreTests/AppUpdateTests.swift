import Foundation
@testable import G2EditorCore
import XCTest

final class AppUpdateTests: XCTestCase {
    private func version(_ text: String) -> AppVersion {
        AppVersion(text)!
    }

    func testVersionsCompareNumberByNumber() {
        XCTAssertLessThan(version("0.9"), version("0.10"))
        XCTAssertLessThan(version("0.1.0"), version("0.1.1"))
        XCTAssertLessThan(version("0.1.9"), version("1.0"))
        XCTAssertEqual(version("0.1"), version("0.1.0"))
        XCTAssertFalse(version("0.1.0") < version("0.1"))
    }

    func testReleaseTagsAreRead() {
        XCTAssertEqual(version("v0.1.2"), version("0.1.2"))
        XCTAssertEqual(version("v0.2.0-beta"), version("0.2"))
        XCTAssertNil(AppVersion("beta"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("0..1"))
    }

    func testOfferSkipsCurrentAndSkippedVersions() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let release = AppRelease(version: version("0.1.2"), notes: "", pageURL: url)
        XCTAssertEqual(UpdateCheck.offer(release, current: version("0.1.1"), skipped: nil), release)
        XCTAssertNil(UpdateCheck.offer(release, current: version("0.1.2"), skipped: nil))
        XCTAssertNil(UpdateCheck.offer(release, current: version("0.2"), skipped: nil))
        XCTAssertNil(UpdateCheck.offer(release, current: version("0.1.1"), skipped: version("0.1.2")))
        // Pominięta była starsza — nowsze wydanie znów się pokazuje.
        XCTAssertEqual(UpdateCheck.offer(release, current: version("0.1.0"), skipped: version("0.1.1")), release)
    }

    func testCheckIsDueOncePerDay() {
        let now = Date()
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastChecked: now.addingTimeInterval(-UpdateCheck.interval), now: now))
    }

    func testNewestReleaseIsPickedFromGitHubList() {
        let json = """
        [
          {"tag_name": "v0.3.0", "body": "draft", "html_url": "https://github.com/r/3", "draft": true},
          {"tag_name": "v0.1.1", "body": "older", "html_url": "https://github.com/r/1", "draft": false},
          {"tag_name": "v0.2.0-beta", "body": "- Fixed cables", "html_url": "https://github.com/r/2",
           "draft": false, "prerelease": true},
          {"tag_name": "nightly", "body": null, "html_url": "https://github.com/r/n", "draft": false}
        ]
        """
        guard case let .found(release) = UpdateCheck.newest(fromReleasesJSON: Data(json.utf8)) else {
            return XCTFail("expected a release")
        }
        XCTAssertEqual(release.version, version("0.2"))
        XCTAssertEqual(release.notes, "- Fixed cables")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/r/2")
    }

    func testEmptyAndBrokenResponses() {
        XCTAssertEqual(UpdateCheck.newest(fromReleasesJSON: Data("[]".utf8)), .noReleases)
        XCTAssertEqual(UpdateCheck.newest(fromReleasesJSON: Data(#"{"message": "Not Found"}"#.utf8)), .failed)
    }
}
