import XCTest
@testable import MacTools

final class LauncherSearchTests: XCTestCase {
    func testPinyinInitialsAndNormalizedNamesMatch() throws {
        let profile = LauncherSearchProfile(title: "微信", keywords: ["WeChat"])
        XCTAssertEqual(LauncherSearch.tier(query: "wx", profile: profile, alias: nil), 4)
        XCTAssertEqual(LauncherSearch.tier(query: "weixin", profile: profile, alias: nil), 4)
        XCTAssertEqual(LauncherSearch.tier(query: "微信", profile: profile, alias: nil), 5)
        XCTAssertEqual(LauncherSearch.normalize(" ＡＢＣ É "), "abc e")
    }
    func testMatchQualityPrecedesPersonalizationAndRejectsUnrelatedText() {
        let profile = LauncherSearchProfile(title: "Visual Studio Code", keywords: ["editor"])
        XCTAssertEqual(LauncherSearch.tier(query: "code", profile: profile, alias: "code"), 6)
        XCTAssertEqual(LauncherSearch.tier(query: "vsc", profile: profile, alias: nil), 4)
        XCTAssertEqual(LauncherSearch.tier(query: "editor", profile: profile, alias: nil), 1)
        XCTAssertNil(LauncherSearch.tier(query: "unrelated", profile: profile, alias: nil))
    }
}
