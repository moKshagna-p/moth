import AppKit
import XCTest
@testable import MothNative

private var submittedSearchCommand = ""

@MainActor final class SearchSuggestionsTests: XCTestCase {
    private func entry(_ query: String, engine: String = "google") -> SavedEntry {
        SavedEntry(url: SearchSuggestions.searchURL(query, engine: engine), title: query + " - Search")
    }

    func testRecognizesSupportedSearchPagesAndDecodesFormQueries() {
        XCTAssertEqual(SearchSuggestions.searchTerm(in: "https://www.google.com/search?q=c%2B%2B+guide&source=chrome"), "c++ guide")
        XCTAssertEqual(SearchSuggestions.searchTerm(in: "https://duckduckgo.com/?q=caf%C3%A9%20recipes"), "café recipes")
        XCTAssertEqual(SearchSuggestions.searchTerm(in: "https://www.bing.com/search?q=rust%20language"), "rust language")
        for address in [
            "https://google.com.evil.example/search?q=secret",
            "https://example.com/search?q=secret",
            "https://www.google.com/maps?q=secret",
            "https://www.google.com:444/search?q=secret",
            "https://user:password@www.google.com/search?q=secret",
            "file://www.google.com/search?q=secret",
            "https://www.google.com/search?q=one&q=two",
            "https://www.google.com/search?q=",
            "https://www.google.com/search?q=line%0Abreak",
            "not a URL"
        ] { XCTAssertNil(SearchSuggestions.searchTerm(in: address), address) }
    }

    func testPrefixCompletionsAreRecentDeduplicatedAndBounded() {
        let history = [entry("Café recipes"), entry("cafe recipes", engine: "bing"),
            entry("cafe"), entry("other cafe"), entry("cafe near me"), entry("cafe menu"),
            entry("cafe hours"), entry("cafe open"), entry("cafe sixth")]
        let results = SearchSuggestions.results(query: "  CAFE ", history: history, engine: "duckduckgo", privateMode: false)
        XCTAssertEqual(results.map(\.title), ["Café recipes", "cafe near me", "cafe menu", "cafe hours", "cafe open"])
        XCTAssertEqual(Set(results.map(\.id)).count, results.count)
        XCTAssertEqual(results.first?.completion, "Café recipes")
        XCTAssertEqual(results.first?.command, "open_new_tab")
        XCTAssertEqual(results.first?.values["value"] as? String, "https://duckduckgo.com/?q=Caf%C3%A9%20recipes")
        XCTAssertTrue(SearchSuggestions.results(query: " ", history: history, engine: "google", privateMode: false).isEmpty)
        XCTAssertTrue(SearchSuggestions.results(query: "cafe", history: history, engine: "google", privateMode: true).isEmpty)
        XCTAssertTrue(SearchSuggestions.results(query: "unrelated", history: history, engine: "google", privateMode: false).isEmpty)
        XCTAssertTrue(SearchSuggestions.results(query: "cafe", history: [], engine: "google", privateMode: false).isEmpty)
    }

    func testSearchURLPreservesLiteralQueriesAndUsesCurrentEngine() {
        let term = "c++ & swift.org #1? 日本語"
        for engine in ["google", "bing", "duckduckgo", "unknown"] {
            let address = SearchSuggestions.searchURL(term, engine: engine)
            XCTAssertEqual(SearchSuggestions.searchTerm(in: address), term)
            XCTAssertTrue(address.contains("%2B%2B"))
            XCTAssertTrue(address.contains("%26"))
            XCTAssertTrue(address.contains("%23"))
        }
    }

    private func snapshot(privateMode: Bool = false, queries: [String] = ["rust language", "rust book"]) throws -> ChromeSnapshot {
        let json = #"""
        {"tabs":[],"bookmarks":[],"history":[],"workspaces":[{"id":1,"name":"Personal","project":{"local":"","repository":"","docs":"","staging":"","production":"","split":false}}],
         "active":0,"active_workspace":1,"private_mode":false,"split_ratio":0.5,
         "settings":{"search_engine":"google","download_directory":"","restore_session":true,"appearance":"system","site_permissions":{}},
         "bookmarked":false,"can_go_back":false,"can_go_forward":false,"has_photo":false,"photo_version":0,"photo_focus_x":50,"photo_focus_y":50}
        """#
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        object["private_mode"] = privateMode
        object["history"] = queries.map { ["url": entry($0).url, "title": $0 + " - Search"] }
        return try JSONDecoder().decode(ChromeSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testPaletteKeepsLiteralNavigationFirstAndDoesNotDuplicateHistoryRows() throws {
        let state = try snapshot()
        let results = PaletteSearch.results(snapshot: state, query: "rust", newTab: true)
        XCTAssertEqual(results.first?.id, "navigate")
        XCTAssertEqual(results.first?.values["value"] as? String, "rust")
        XCTAssertEqual(results.compactMap(\.completion), ["rust language", "rust book"])
        XCTAssertFalse(results.contains { $0.id.hasPrefix("saved:") })
        XCTAssertFalse(PaletteSearch.results(snapshot: state, query: "", newTab: true).contains { $0.completion != nil })
        XCTAssertFalse(PaletteSearch.results(snapshot: state, query: "rust", newTab: false).contains { $0.completion != nil })
        XCTAssertFalse(PaletteSearch.results(snapshot: try snapshot(privateMode: true), query: "rust", newTab: true).contains { $0.completion != nil })
    }

    func testTabCompletionIsExplicitAndKeyboardSelectionCanSubmitSuggestions() throws {
        _ = NSApplication.shared
        let model = ChromeModel()
        model.snapshot = try snapshot()
        model.showNewTab()
        model.paletteQuery = "rust"
        XCTAssertEqual(model.paletteQuery, "rust")
        XCTAssertEqual(model.paletteSelection, 0)
        model.movePalette(1)
        XCTAssertEqual(model.paletteResults[model.paletteSelection].completion, "rust language")
        model.movePalette(1)
        XCTAssertTrue(model.completePalette())
        XCTAssertEqual(model.paletteQuery, "rust book")
        XCTAssertEqual(model.paletteSelection, 0)
        model.paletteQuery = "rust"
        XCTAssertTrue(model.completePalette())
        XCTAssertEqual(model.paletteQuery, "rust language")
        model.paletteQuery = "rust"
        model.movePalette(1)
        model.submitPalette()
        XCTAssertNil(model.paletteMode)
        model.showSwitcher()
        model.paletteQuery = "rust"
        XCTAssertFalse(model.completePalette())
    }

    func testInputMethodCompositionDoesNotAcceptSuggestions() throws {
        _ = NSApplication.shared
        let model = ChromeModel()
        model.snapshot = try snapshot()
        model.showNewTab()
        model.paletteQuery = "rust"
        let coordinator = PaletteInput.Coordinator(model: model)
        let editor = NSTextView()
        editor.setMarkedText("ru", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(coordinator.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(model.paletteQuery, "rust")
        editor.unmarkText()
        XCTAssertTrue(coordinator.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(model.paletteQuery, "rust language")
    }

    func testCompletedDomainLikeSearchKeepsSearchIntentUntilEdited() throws {
        _ = NSApplication.shared
        let model = ChromeModel()
        model.snapshot = try snapshot(queries: ["swift.org"])
        model.callback = { pointer in submittedSearchCommand = pointer.map(String.init(cString:)) ?? "" }
        model.showNewTab()
        model.paletteQuery = "swift"
        XCTAssertTrue(model.completePalette())
        XCTAssertEqual(model.paletteQuery, "swift.org")
        model.submitPalette()
        let command = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(submittedSearchCommand.utf8)) as? [String: Any])
        XCTAssertEqual(command["value"] as? String, "https://www.google.com/search?q=swift.org")
        model.showNewTab()
        model.paletteQuery = "swift"
        XCTAssertTrue(model.completePalette())
        model.paletteQuery = "example.com"
        XCTAssertNil(model.paletteCompletedSearchURL)
        model.submitPalette()
        let edited = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(submittedSearchCommand.utf8)) as? [String: Any])
        XCTAssertEqual(edited["value"] as? String, "example.com")
    }
}
