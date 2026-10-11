import AppKit
import Combine
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

    private func snapshot(privateMode: Bool = false, queries: [String] = ["rust language", "rust book"], engine: String = "google") throws -> ChromeSnapshot {
        let json = #"""
        {"tabs":[],"bookmarks":[],"history":[],"workspaces":[{"id":1,"name":"Personal","project":{"local":"","repository":"","docs":"","staging":"","production":"","split":false}}],
         "active":0,"active_workspace":1,"private_mode":false,"split_ratio":0.5,
         "settings":{"search_engine":"google","download_directory":"","restore_session":true,"appearance":"system","site_permissions":{}},
         "bookmarked":false,"can_go_back":false,"can_go_forward":false,"has_photo":false,"photo_version":0,"photo_focus_x":50,"photo_focus_y":50}
        """#
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        object["private_mode"] = privateMode
        var settings = object["settings"] as! [String: Any]
        settings["search_engine"] = engine
        object["settings"] = settings
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
        let model = ChromeModel(suggestionFetch: { _, _ in [] })
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
        let model = ChromeModel(suggestionFetch: { _, _ in [] })
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
        let model = ChromeModel(suggestionFetch: { _, _ in [] })
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

    func testLiveQueriesExcludeAddressesAndEncodeLiteralSearchesForEachEngine() throws {
        for query in ["", "a", "https://example.com/secret", "localhost:3000", "127.0.0.1", "[::1]",
                      "example.com", "/Users/me/private", "user@example.com", "token=secret", "line\nbreak", "about:blank"] {
            XCTAssertNil(SearchSuggestions.requestURL(query: query, engine: "google"), query)
        }
        for (engine, host, name) in [("google", "www.google.com", "q"), ("bing", "www.bing.com", "query"), ("duckduckgo", "duckduckgo.com", "q")] {
            let url = try XCTUnwrap(SearchSuggestions.requestURL(query: "c++ & 日本語", engine: engine))
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.host, host)
            XCTAssertEqual(parts.queryItems?.first(where: { $0.name == name })?.value, "c++ & 日本語")
            XCTAssertTrue(url.absoluteString.contains("%2B%2B"))
        }
    }

    func testLiveResponsesAreValidatedBoundedAndMergedWithoutHistory() throws {
        let payload = Data(#"["book my", ["bookmyshow", "BOOKMYSHOW", "book my", "https://in.bookmyshow.com/", "book my tickets", "bad\nline"]]"#.utf8)
        let terms = SearchSuggestions.parseResponse(payload, query: "book my")
        XCTAssertEqual(terms, ["bookmyshow", "book my tickets"])
        XCTAssertTrue(SearchSuggestions.parseResponse(payload, query: "other").isEmpty)
        for invalid in ["{}", "[\"book my\", {}]", "[\"book my\", [1]]", "invalid"] {
            XCTAssertTrue(SearchSuggestions.parseResponse(Data(invalid.utf8), query: "book my").isEmpty)
        }
        XCTAssertTrue(SearchSuggestions.parseResponse(Data(repeating: 32, count: 65_537), query: "book my").isEmpty)
        let results = PaletteSearch.results(snapshot: try snapshot(queries: []), query: "book my", newTab: true, remoteSuggestions: terms)
        XCTAssertEqual(results.first?.values["value"] as? String, "book my")
        XCTAssertEqual(results.compactMap(\.completion), terms)
        XCTAssertEqual(results[1].subtitle, "Search suggestion")
        XCTAssertEqual(results[1].values["value"] as? String, "https://www.google.com/search?q=bookmyshow")
        let merged = SearchSuggestions.results(query: "book my", history: [entry("bookmyshow")], engine: "bing", privateMode: false, remote: terms)
        XCTAssertEqual(merged.compactMap(\.completion), terms)
        XCTAssertTrue(SearchSuggestions.results(query: "book my", history: [], engine: "google", privateMode: true, remote: terms).isEmpty)
    }

    func testDebounceOnlyFetchesLatestQueryAndFailuresKeepLocalResults() async {
        let fetched = expectation(description: "debounced fetch")
        var calls: [String] = []
        let suggestions = LiveSearchSuggestions(delay: 10_000_000, fetch: { query, _ in
            calls.append(query)
            fetched.fulfill()
            throw URLError(.notConnectedToInternet)
        }, receive: { terms in XCTAssertTrue(terms.isEmpty) })
        suggestions.update(query: "bo", engine: "google", enabled: true)
        suggestions.update(query: "book my", engine: "google", enabled: true)
        await fulfillment(of: [fetched], timeout: 1)
        XCTAssertEqual(calls, ["book my"])
        suggestions.update(query: "book my", engine: "google", enabled: false)
    }

    func testStaleResponsesCannotReplaceNewerResultsOrReturnAfterDismissal() async {
        let first = expectation(description: "first request")
        let second = expectation(description: "second request")
        let delivered = expectation(description: "new results delivered")
        let stale = expectation(description: "stale results must be ignored")
        stale.isInverted = true
        var pending: [String: CheckedContinuation<[String], Never>] = [:]
        let suggestions = LiveSearchSuggestions(delay: 0, fetch: { query, _ in
            await withCheckedContinuation { continuation in
                pending[query] = continuation
                (query == "book" ? first : second).fulfill()
            }
        }, receive: { terms in
            if terms == ["bookmyshow"] { delivered.fulfill() }
            if terms == ["old result"] { stale.fulfill() }
        })
        suggestions.update(query: "book", engine: "google", enabled: true)
        await fulfillment(of: [first], timeout: 1)
        suggestions.update(query: "book my", engine: "google", enabled: true)
        await fulfillment(of: [second], timeout: 1)
        pending.removeValue(forKey: "book my")?.resume(returning: ["bookmyshow"])
        await fulfillment(of: [delivered], timeout: 1)
        suggestions.update(query: "", engine: "google", enabled: false)
        pending.removeValue(forKey: "book")?.resume(returning: ["old result"])
        await fulfillment(of: [stale], timeout: 0.05)
    }

    func testPrivateWindowsSwitcherAndCompositionNeverRequestPredictions() async throws {
        _ = NSApplication.shared
        var calls: [String] = []
        let fetched = expectation(description: "committed normal query")
        let model = ChromeModel(suggestionDelay: 0, suggestionFetch: { query, engine in
            calls.append(engine + ":" + query)
            fetched.fulfill()
            return ["bookmyshow"]
        })
        model.snapshot = try snapshot(privateMode: true, queries: [])
        model.showNewTab()
        model.paletteQuery = "book my"
        await Task.yield()
        XCTAssertTrue(calls.isEmpty)
        model.closePalette()
        model.snapshot = try snapshot(queries: [])
        model.showSwitcher()
        model.paletteQuery = "book my"
        await Task.yield()
        XCTAssertTrue(calls.isEmpty)
        model.showNewTab()
        model.setPaletteInput("book my", composing: true)
        await Task.yield()
        XCTAssertTrue(calls.isEmpty)
        let delivered = expectation(description: "model displays predictions")
        let observation = model.$paletteResults.filter { $0.contains { $0.completion == "bookmyshow" } }.first()
            .sink { _ in delivered.fulfill() }
        defer { observation.cancel() }
        model.setPaletteInput("book my", composing: false)
        await fulfillment(of: [fetched, delivered], timeout: 1)
        XCTAssertEqual(calls, ["google:book my"])
        XCTAssertTrue(model.paletteResults.contains { $0.completion == "bookmyshow" })
        model.snapshot = try snapshot(privateMode: true, queries: [])
        XCTAssertFalse(model.paletteResults.contains { $0.completion != nil })
        model.closePalette()
    }

    func testEngineChangesCancelThePreviousProvider() async {
        let started = expectation(description: "Google started")
        let switched = expectation(description: "Bing completed")
        let stale = expectation(description: "old provider is ignored")
        stale.isInverted = true
        var google: CheckedContinuation<[String], Never>?
        let suggestions = LiveSearchSuggestions(delay: 0, fetch: { _, engine in
            if engine == "google" {
                return await withCheckedContinuation { google = $0; started.fulfill() }
            }
            return ["Bing result"]
        }, receive: { terms in
            if terms == ["Bing result"] { switched.fulfill() }
            if terms == ["Google result"] { stale.fulfill() }
        })
        suggestions.update(query: "book my", engine: "google", enabled: true)
        await fulfillment(of: [started], timeout: 1)
        suggestions.update(query: "book my", engine: "bing", enabled: true)
        await fulfillment(of: [switched], timeout: 1)
        google?.resume(returning: ["Google result"])
        await fulfillment(of: [stale], timeout: 0.05)
        suggestions.update(query: "", engine: "bing", enabled: false)
    }


    func testDismissalCancelsAnInflightRequest() async {
        let started = expectation(description: "request started")
        let stale = expectation(description: "dismissed results must be ignored")
        stale.isInverted = true
        var pending: CheckedContinuation<[String], Never>?
        let suggestions = LiveSearchSuggestions(delay: 0, fetch: { _, _ in
            await withCheckedContinuation { pending = $0; started.fulfill() }
        }, receive: { if !$0.isEmpty { stale.fulfill() } })
        suggestions.update(query: "book my", engine: "google", enabled: true)
        await fulfillment(of: [started], timeout: 1)
        suggestions.update(query: "book my", engine: "google", enabled: false)
        pending?.resume(returning: ["bookmyshow"])
        await fulfillment(of: [stale], timeout: 0.05)
    }

}
