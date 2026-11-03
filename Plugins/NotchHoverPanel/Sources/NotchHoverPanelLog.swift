import Foundation
import OSLog

enum NotchHoverPanelLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "cc.ggbond.mactools"

    static let controller = Logger(subsystem: subsystem, category: "NotchHoverPanel")
}
