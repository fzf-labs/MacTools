import Foundation
import XCTest
@testable import AutoInputPlugin

final class AutoInputWebsiteRuleTests: XCTestCase {
    func testDomainMatchingRespectsHostBoundariesAndBrowserScope() {
        var rule = AutoInputWebsiteRule()
        rule.pattern = "Example.COM."
        rule.inputSourceID = "en"
        let browser = "com.google.Chrome"
        XCTAssertTrue(rule.matches(URL(string: "https://example.com/")!, browserBundleIdentifier: browser))
        XCTAssertTrue(rule.matches(URL(string: "https://work.example.com/edit")!, browserBundleIdentifier: browser))
        XCTAssertFalse(rule.matches(URL(string: "https://notexample.com/")!, browserBundleIdentifier: browser))
        rule.match = .domain
        XCTAssertFalse(rule.matches(URL(string: "https://work.example.com/")!, browserBundleIdentifier: browser))
        rule.browserBundleIdentifier = "com.apple.Safari"
        XCTAssertFalse(rule.matches(URL(string: "https://example.com/")!, browserBundleIdentifier: browser))
        rule.isEnabled = false
        XCTAssertFalse(rule.matches(URL(string: "https://example.com/")!, browserBundleIdentifier: "com.apple.Safari"))
    }

    func testURLExpressionsValidateAndIgnoreNonWebPages() {
        var rule = AutoInputWebsiteRule()
        rule.match = .urlRegex
        rule.pattern = #"^https://example\.com/work/"#
        rule.inputSourceID = "zh"
        XCTAssertTrue(rule.matches(URL(string: "https://example.com/work/edit")!, browserBundleIdentifier: "com.apple.Safari"))
        XCTAssertFalse(rule.matches(URL(string: "https://example.com/personal/")!, browserBundleIdentifier: "com.apple.Safari"))
        rule.pattern = "["
        XCTAssertFalse(rule.isValid)
        rule.match = .domainSuffix
        for pattern in ["https://example.com", "example.com/path", "example.com:443", "", "user@example.com"] {
            rule.pattern = pattern
            XCTAssertFalse(rule.isValid, pattern)
        }
        rule.pattern = "example.com"
        XCTAssertFalse(rule.matches(URL(string: "file://example.com/page")!, browserBundleIdentifier: "com.apple.Safari"))
    }
}
