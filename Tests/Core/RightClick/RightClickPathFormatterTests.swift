import AppKit
import XCTest
@testable import MacTools

final class RightClickPathFormatterTests: XCTestCase {

    func testShellEscapedEscapesEmbeddedSingleQuote() {
        XCTAssertEqual(
            RightClickPathFormatter.shellEscaped("/a/it's.txt"),
            "'/a/it'\\''s.txt'"
        )
    }

}
