import AppKit
import WebKit
import XCTest
@testable import MothNative

@MainActor final class PopupTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(predicate())
    }
    private func evaluate(_ script: String, in view: WKWebView) -> Any? {
        var done = false; var result: Any?
        view.evaluateJavaScript(script) { value, error in
            XCTAssertNil(error); result = value; done = true
        }
        waitUntil { done }; return result
    }
    func testPopupKeepsOpenerMessagesPrivateStoreAndCloses() {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 500), configuration: configuration)
        view.customUserAgent = "Moth popup regression agent"
        let page = PageDelegate(window: 998, id: 1, generation: 1, webView: view)
        view.navigationDelegate = page; view.uiDelegate = page
        defer { page.closePopups() }
        view.loadHTMLString("<html><body>Opener</body></html>", baseURL: URL(string: "https://example.com"))
        waitUntil { !view.isLoading }
        _ = evaluate("window.messages=[];window.addEventListener('message',e=>messages.push(e.data));window.child=window.open('about:blank','login');Boolean(child)", in: view)
        waitUntil { page.popups.count == 1 }
        let popup = page.popups.values.first!
        XCTAssertTrue(popup.webView.configuration.websiteDataStore === configuration.websiteDataStore)
        XCTAssertFalse(popup.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertEqual(popup.webView.customUserAgent, view.customUserAgent)
        waitUntil { !popup.webView.isLoading }
        XCTAssertEqual(evaluate("window.opener !== null", in: popup.webView) as? Bool, true)
        _ = evaluate("window.opener.postMessage('login-result','*')", in: popup.webView)
        var received = false
        let deadline = Date().addingTimeInterval(15)
        while !received, Date() < deadline {
            received = evaluate("messages.includes('login-result')", in: view) as? Bool == true
        }
        XCTAssertTrue(received)
        _ = evaluate("window.close()", in: popup.webView)
        waitUntil { page.popups.isEmpty }
        XCTAssertFalse(popup.window.isVisible)
    }
    func testParentCleanupClosesPopups() {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 500), configuration: configuration)
        let page = PageDelegate(window: 998, id: 2, generation: 1, webView: view)
        view.navigationDelegate = page; view.uiDelegate = page
        view.loadHTMLString("<html>Opener</html>", baseURL: URL(string: "https://example.com"))
        waitUntil { !view.isLoading }
        _ = evaluate("window.child=window.open('about:blank');Boolean(child)", in: view)
        waitUntil { page.popups.count == 1 }
        let popup = page.popups.values.first!
        _ = evaluate("window.close = () => false;true", in: popup.webView)
        page.closePopups()
        XCTAssertTrue(page.popups.isEmpty)
        XCTAssertFalse(popup.window.isVisible)
        XCTAssertNil(popup.window.contentView)
        waitUntil { self.evaluate("child.closed", in: view) as? Bool == true }
    }
}
