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
    func testMovingPopupPreservesLiveDocumentAndSeparatesLifetime() {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let openerView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 500), configuration: configuration)
        let opener = PageDelegate(window: 996, id: 1, generation: 1, webView: openerView)
        openerView.navigationDelegate = opener; openerView.uiDelegate = opener
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        let bridge = ChromeBridge(); bridge.parent = parent
        ChromeBridge.instances[996] = bridge
        BrowserFeatures.pages["996:1"] = opener
        defer {
            opener.closePopups()
            BrowserFeatures.pages.removeValue(forKey: "996:1")
            BrowserFeatures.pages.removeValue(forKey: "996:2")
            ChromeBridge.instances.removeValue(forKey: 996)
        }
        openerView.loadHTMLString("<html>Opener</html>", baseURL: URL(string: "https://example.com"))
        waitUntil { !openerView.isLoading }
        _ = evaluate("window.child=window.open('about:blank');Boolean(child)", in: openerView)
        waitUntil { opener.popups.count == 1 }
        let popup = opener.popups.values.first!
        waitUntil { !popup.webView.isLoading }
        popup.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://example.com/mini")!),
                                           responseHTML: "<html><body><input id='state'></body></html>")
        waitUntil { !popup.webView.isLoading }
        _ = evaluate("state.value='unsaved work';window.marker={value:42};history.pushState({},'', '#before-merge');true", in: popup.webView)
        waitUntil { popup.webView.canGoBack }
        popup.toggleFitToWindow()
        // A missing target window and an occupied tab ID must leave the popup alone.
        XCTAssertFalse(popup.id.uuidString.withCString { moth_popup_merge(995, $0, 2, 1) })
        XCTAssertFalse(popup.id.uuidString.withCString { moth_popup_merge(996, $0, 1, 1) })
        XCTAssertTrue(popup.window.isVisible)
        XCTAssertTrue(popup.id.uuidString.withCString { moth_popup_merge(996, $0, 2, 7) })
        XCTAssertTrue(BrowserFeatures.pages["996:2"] === popup.page)
        XCTAssertTrue(popup.page.container.superview === parent)
        XCTAssertEqual(popup.page.id, 2); XCTAssertEqual(popup.page.generation, 7)
        XCTAssertTrue(popup.page.fitToWindow)
        XCTAssertTrue(popup.webView.configuration.websiteDataStore === configuration.websiteDataStore)
        XCTAssertFalse(popup.window.isVisible); XCTAssertNil(popup.window.contentView)
        XCTAssertTrue(opener.popups.isEmpty)
        opener.closePopups()
        XCTAssertEqual(evaluate("state.value", in: popup.webView) as? String, "unsaved work")
        XCTAssertEqual(evaluate("marker.value", in: popup.webView) as? Int, 42)
        XCTAssertEqual(evaluate("window.opener !== null", in: popup.webView) as? Bool, true)
        XCTAssertEqual(evaluate("child.closed", in: openerView) as? Bool, false)
        XCTAssertTrue(popup.webView.canGoBack)
        popup.webView.goBack()
        waitUntil { popup.webView.url?.fragment != "before-merge" }
        XCTAssertEqual(evaluate("state.value", in: popup.webView) as? String, "unsaved work")
        "close".withCString { operation in
            "".withCString { argument in
                moth_page_operation(996, 2, operation, argument, { _, _ in }, nil)
            }
        }
        XCTAssertNil(BrowserFeatures.pages["996:2"])
        waitUntil { self.evaluate("child.closed", in: openerView) as? Bool == true }
    }

    func testFitToWindowTracksPaneWidthAndRestoresUserZoom() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 1100, height: 700))
        window.contentView = parent
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 512, height: 600))
        parent.addSubview(view)
        let page = PageDelegate(window: 997, id: 1, generation: 1, webView: view)
        view.navigationDelegate = page; view.uiDelegate = page
        BrowserFeatures.pages["997:1"] = page
        defer { BrowserFeatures.pages.removeValue(forKey: "997:1"); window.close() }
        view.loadHTMLString("<html><body style='margin:0'><div style='width:1024px'>Desktop layout</div></body></html>", baseURL: nil)
        waitUntil { !view.isLoading }
        XCTAssertEqual((evaluate("innerWidth", in: view) as? NSNumber)?.intValue, 512)
        moth_page_zoom(997, 1, 1, true)
        XCTAssertEqual(view.pageZoom, 0.5, accuracy: 0.001)
        waitUntil { (self.evaluate("innerWidth", in: view) as? NSNumber)?.intValue == 1024 }
        moth_page_layout(997, 1, 0, 0, 384, 600)
        XCTAssertEqual(view.pageZoom, 0.375, accuracy: 0.001)
        waitUntil { (self.evaluate("innerWidth", in: view) as? NSNumber)?.intValue == 1024 }
        moth_page_zoom(997, 1, 1.25, true)
        XCTAssertEqual(view.pageZoom, 0.46875, accuracy: 0.001)
        moth_page_zoom(997, 1, 1.25, false)
        XCTAssertEqual(view.pageZoom, 1.25, accuracy: 0.001)
        moth_page_zoom(997, 1, 1, false)
        waitUntil { (self.evaluate("innerWidth", in: view) as? NSNumber)?.intValue == 384 }
        moth_page_zoom(997, 1, 1, true)
        moth_page_layout(997, 1, 0, 0, 1100, 600)
        XCTAssertEqual(view.pageZoom, 1, accuracy: 0.001)
        waitUntil { (self.evaluate("innerWidth", in: view) as? NSNumber)?.intValue == 1100 }
    }

}
