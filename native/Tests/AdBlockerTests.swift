import AppKit
import WebKit
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
