import XCTest
@testable import MacTools

final class PluginListFilterTests: XCTestCase {
    @MainActor
    func testActivationFilterCombinesWithSearchAndCategoryCounts() {
        func item(_ id: String, category: String, installed: Bool = true,
                  enabled: Bool = true) -> PluginManagementItem {
            PluginManagementItem(id: id, title: id, summary: nil, version: "1.0.0",
                state: installed ? .installed : .available,
                packageURL: installed ? URL(fileURLWithPath: "/tmp/\(id).mactoolsplugin") : nil,
                requiresRestartToFullyUnload: false, releaseNotesURL: nil,
                category: category, isEnabled: enabled)
        }
        let items = [
            item("system-active", category: "system"),
            item("system-stopped", category: "system", enabled: false),
            item("monitor-stopped", category: "monitoring", enabled: false),
            item("system-available", category: "system", installed: false),
        ]
        XCTAssertEqual(items.filter { PluginActivationFilter.all.contains($0) }.count, 4)
        XCTAssertEqual(items.filter { PluginActivationFilter.enabled.contains($0) }.map(\.id), ["system-active"])
        XCTAssertEqual(items.filter { PluginActivationFilter.disabled.contains($0) }.map(\.id),
                       ["system-stopped", "monitor-stopped"])
        XCTAssertEqual(items.filter {
            PluginListFilter.matches(managementItem: $0, query: "SYSTEM", filter: .category(.system),
                                     activationFilter: .disabled)
        }.map(\.id), ["system-stopped"])
        let counts = PluginListFilter.countsByFilter(managementItems: items, query: "", activationFilter: .disabled)
        XCTAssertEqual(counts[.all], 2)
        XCTAssertEqual(counts[.category(.system)], 1)
        XCTAssertEqual(counts[.category(.monitoring)], 1)
    }

    func testTurkishCapitalizationMatchesInBothDirections() {
        for (query, text) in [
            ("iç içe klasörler", "İç içe klasörler"),
            ("istem şablonu", "İstem Şablonu"),
            ("imleci izle", "İmleci İzle"),
            ("izleme dörtgeni hareketi", "İzleme Dörtgeni Hareketi"),
            ("Işığı azaltın", "ışığı azaltın"),
            ("Ortam Işığına", "Ortam ışığına"),
            ("Uygulama Izgarasını", "Uygulama ızgarasını"),
            ("I\u{0307}ç", "iç"),
        ] {
            XCTAssertTrue(PluginListFilter.matches(query: query, in: [text]), query)
            XCTAssertTrue(PluginListFilter.matches(query: text, in: [query]), text)
        }
        for query in ["I", "İ", "ı", "i"] {
            for text in ["I", "İ", "ı", "i"] {
                XCTAssertTrue(PluginListFilter.matches(query: query, in: [text]), "\(query) in \(text)")
            }
        }
    }

    func testGermanSharpSMatchesItsCapitalizationVariants() {
        for (query, text) in [
            ("FENSTERHÖHE VERGRÖSSERN", "Fensterhöhe vergrößern"),
            ("ANGEMESSENE GRÖSSE", "Angemessene Größe"),
            ("Straße", "STRASSE"),
            ("STRAẞE", "Straße"),
        ] {
            XCTAssertTrue(PluginListFilter.matches(query: query, in: [text]), query)
            XCTAssertTrue(PluginListFilter.matches(query: text, in: [query]), text)
        }
    }

    func testCanonicalUnicodeAndExistingSubstringBoundaries() {
        XCTAssertTrue(PluginListFilter.matches(query: "  DE\u{0301}FILEMENT  ", in: [nil, "Défilement fluide"]))
        XCTAssertFalse(PluginListFilter.matches(query: "Defilement", in: ["Défilement fluide"]))
        XCTAssertFalse(PluginListFilter.matches(query: "isik", in: ["Işık"]))
        XCTAssertTrue(PluginListFilter.matches(query: "  CPU  ", in: ["CPU monitor"]))
        XCTAssertTrue(PluginListFilter.matches(query: " \n ", in: [nil]))
        XCTAssertFalse(PluginListFilter.matches(query: "missing", in: [nil]))
    }
}
