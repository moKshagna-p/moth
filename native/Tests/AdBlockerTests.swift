import AppKit
import WebKit
import Network
import XCTest
@testable import MothNative

@MainActor final class AdBlockerTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(predicate())
    }
    private func display(_ view: WKWebView, base: String) -> [String] {
        var result: [String]?
        view.loadHTMLString("<html><body><ins class='adsbygoogle' id='advert'>Ad</ins><article id='content'>Article</article></body></html>", baseURL: URL(string: base))
        waitUntil { !view.isLoading }
        view.evaluateJavaScript("[getComputedStyle(document.getElementById('advert')).display,getComputedStyle(document.getElementById('content')).display]") { value, _ in result = value as? [String] }
        waitUntil { result != nil }
        return result!
    }
    func testDomainFiltersHaveHostBoundaries() throws {
        let pattern = try NSRegularExpression(pattern: AdBlocker.filter(for: "doubleclick.net"))
        func matches(_ value: String) -> Bool { pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil }
        XCTAssertTrue(matches("https://ad.doubleclick.net/banner"))
        XCTAssertTrue(matches("http://doubleclick.net:8080/ad"))
        XCTAssertFalse(matches("https://notdoubleclick.net/banner"))
        XCTAssertFalse(matches("https://doubleclick.net.example.com/banner"))
        XCTAssertFalse(matches("https://example.com/?ad=https://doubleclick.net/banner"))
        XCTAssertFalse(matches("https://doubleclick.net@example.com/banner"))
        XCTAssertFalse(AdBlockPreferences().blocks(host: "localhost"))
        XCTAssertFalse(AdBlockPreferences().blocks(host: "app.localhost"))
        XCTAssertFalse(AdBlockPreferences().blocks(host: "127.0.0.1"))
        XCTAssertTrue(AdBlockPreferences().blocks(host: "example.com"))
        XCTAssertTrue(AdBlockPreferences(exceptions: ["example.com"]).blocks(host: "notexample.com"))
    }
    func testBundledFiltersToggleAndRespectExactSiteExceptions() {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let page = PageDelegate(window: 989, id: 1, generation: 1, webView: view)
        view.navigationDelegate = page
        var prepared = false
        page.prepareAdBlocking { success in XCTAssertTrue(success); prepared = true }
        waitUntil { prepared }
        XCTAssertTrue(page.installedAdRules != nil)
        XCTAssertEqual(display(view, base: "https://example.com"), ["none", "block"])
        page.adPreferences = AdBlockPreferences(enabled: false)
        XCTAssertEqual(display(view, base: "https://example.com"), ["inline", "block"])
        XCTAssertNil(page.installedAdRules)
        page.adPreferences = AdBlockPreferences(exceptions: ["example.com"])
        XCTAssertEqual(display(view, base: "https://example.com"), ["inline", "block"])
        XCTAssertEqual(display(view, base: "https://www.example.com"), ["none", "block"])
        XCTAssertEqual(display(view, base: "https://notexample.com"), ["none", "block"])
        XCTAssertEqual(display(view, base: "http://localhost:3000"), ["inline", "block"])
        XCTAssertEqual(display(view, base: "http://app.localhost:3000"), ["inline", "block"])
        XCTAssertEqual(display(view, base: "http://127.0.0.1:3000"), ["inline", "block"])
        XCTAssertEqual(display(view, base: "http://[::1]:3000"), ["inline", "block"])
    }
    func testNetworkRequestsAreBlockedAndRestoredByExceptions() throws {
        _ = NSApplication.shared
        let server = try NWListener(using: .tcp, on: .any)
        var ready = false, requests = 0
        server.stateUpdateHandler = { state in if case .ready = state { ready = true } }
        server.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard data != nil else { connection.cancel(); return }
                requests += 1
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\nOK"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        server.start(queue: .main)
        defer { server.cancel() }
        waitUntil { ready }
        let port = try XCTUnwrap(server.port?.rawValue)
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        func install(exceptions: [String]) throws {
            var rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(AdBlocker.encodedRules(exceptions: exceptions).utf8)) as? [[String: Any]])
            // Substitute only the first blocked hostname for a hermetic loopback server.
            // The production action, third-party trigger, and top-site exceptions stay intact.
            rules[0]["trigger"] = ["url-filter": AdBlocker.filter(for: "127.0.0.1"), "load-type": ["third-party"]]
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
            var done = false
            configuration.userContentController.removeAllContentRuleLists()
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "Moth.NetworkRegression", encodedContentRuleList: encoded) { list, error in
                XCTAssertNil(error)
                if let list { configuration.userContentController.add(list) }
                done = true
            }
            waitUntil { done }
        }
        func fetch(base: String) -> String? {
            view.loadHTMLString("<html><body>Network fixture</body></html>", baseURL: URL(string: base))
            waitUntil { !view.isLoading }
            view.evaluateJavaScript("window.outcome = ''; fetch('http://127.0.0.1:\(port)/ad', {signal: AbortSignal.timeout(3000)}).then(() => outcome = 'loaded').catch(() => outcome = 'blocked'); true")
            var outcome: String?
            waitUntil {
                var done = false
                view.evaluateJavaScript("window.outcome") { value, _ in outcome = value as? String; done = true }
                let deadline = Date().addingTimeInterval(1)
                while !done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
                return outcome == "loaded" || outcome == "blocked"
            }
            return outcome
        }
        try install(exceptions: [])
        XCTAssertEqual(fetch(base: "http://example.com"), "blocked")
        XCTAssertEqual(requests, 0)
        configuration.userContentController.removeAllContentRuleLists()
        XCTAssertEqual(fetch(base: "http://example.com"), "loaded")
        XCTAssertEqual(requests, 1)
        try install(exceptions: ["example.com"])
        XCTAssertEqual(fetch(base: "http://example.com"), "loaded")
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(fetch(base: "http://www.example.com"), "blocked")
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(fetch(base: "http://localhost"), "loaded")
        XCTAssertEqual(requests, 3)
    }

    func testSettingsChangedDuringCompilationNeverInstallStaleRules() {
        let view = WKWebView()
        let page = PageDelegate(window: 989, id: 2, generation: 1, webView: view)
        page.adPreferences = AdBlockPreferences(exceptions: ["fresh-compilation.example"])
        var completed = 0
        page.prepareAdBlocking { success in XCTAssertTrue(success); completed += 1 }
        page.adPreferences.enabled = false
        page.prepareAdBlocking { success in XCTAssertTrue(success); completed += 1 }
        waitUntil { completed == 2 }
        XCTAssertNil(page.installedAdRules)
    }
    func testLegacySettingsEnableProtectionAndPersistExceptions() throws {
        let settings = try JSONDecoder().decode(BrowserSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.ad_blocking)
        XCTAssertTrue(settings.ad_block_exceptions.isEmpty)
        var updated = settings; updated.ad_blocking = false; updated.ad_block_exceptions = ["example.com"]
        let decoded = try JSONDecoder().decode(BrowserSettings.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(decoded.adPreferences, updated.adPreferences)
    }
}
