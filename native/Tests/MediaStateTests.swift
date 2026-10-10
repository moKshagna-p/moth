import AppKit
import WebKit
import Network
import XCTest
@testable import MothNative

@MainActor private final class SampledWebView: WKWebView {
    var samples: [@MainActor @Sendable (WKMediaPlaybackState) -> Void] = []
    var scripts: [@MainActor @Sendable (Any?, Error?) -> Void] = []
    override func requestMediaPlaybackState(completionHandler: @escaping @MainActor @Sendable (WKMediaPlaybackState) -> Void) {
        samples.append(completionHandler)
    }
    override func evaluateJavaScript(_ javaScriptString: String, completionHandler: (@MainActor @Sendable (Any?, Error?) -> Void)? = nil) {
        if let completionHandler { scripts.append(completionHandler) }
    }
}

@MainActor private final class OriginalNavigation: NSObject, WKNavigationDelegate {
    var starts = 0
    var responses = 0
    var response: WKNavigationResponse?
    var policy: WKNavigationResponsePolicy = .allow
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        responses += 1
        response = navigationResponse
        decisionHandler(policy)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { starts += 1 }
}

@MainActor final class MediaStateTests: XCTestCase {
    func testNavigationResponsePolicyPreservesOriginalDelegate() throws {
        _ = NSApplication.shared
        let server = try NWListener(using: .tcp, on: .any)
        var ready = false
        server.stateUpdateHandler = { state in if case .ready = state { ready = true } }
        server.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let body = "<html><body>Response fixture</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        server.start(queue: .main)
        defer { server.cancel() }
        let readyDeadline = Date().addingTimeInterval(5)
        while !ready, Date() < readyDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(ready)
        let port = try XCTUnwrap(server.port?.rawValue)
        let view = SampledWebView()
        let original = OriginalNavigation()
        view.navigationDelegate = original
        let page = PageDelegate(window: 992, id: 5, generation: 1, webView: view)
        view.navigationDelegate = page
        view.load(URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!))
        let deadline = Date().addingTimeInterval(5)
        while original.response == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let response = try XCTUnwrap(original.response)
        XCTAssertTrue(response.response.url != nil)
        original.policy = .download
        var policy: WKNavigationResponsePolicy?
        page.webView(view, decidePolicyFor: response) { policy = $0 }
        XCTAssertEqual(policy, .download)
        original.policy = .cancel
        page.webView(view, decidePolicyFor: response) { policy = $0 }
        XCTAssertEqual(policy, .cancel)
    }

    func testEmptyPagesSkipScriptsAndOverlappingSamples() {
        _ = NSApplication.shared
        let view = SampledWebView()
        let page = PageDelegate(window: 992, id: 1, generation: 1, webView: view)
        page.updateMediaState(); page.updateMediaState()
        XCTAssertEqual(view.samples.count, 1)
        view.samples.removeFirst()(.none)
        XCTAssertTrue(view.scripts.isEmpty)
        XCTAssertFalse(page.playing)
        page.updateMediaState()
        XCTAssertEqual(view.samples.count, 1)
    }

    func testNavigationDiscardsOldMediaSamplesAndForwardsStart() {
        _ = NSApplication.shared
        let view = SampledWebView()
        let original = OriginalNavigation()
        view.navigationDelegate = original
        let page = PageDelegate(window: 992, id: 2, generation: 1, webView: view)
        page.updateMediaState()
        let stale = view.samples.removeFirst()
        page.playing = true
        page.webView(view, didStartProvisionalNavigation: nil)
        XCTAssertEqual(original.starts, 1)
        XCTAssertFalse(page.playing)
        stale(.playing)
        XCTAssertTrue(view.scripts.isEmpty)
        page.updateMediaState()
        view.samples.removeFirst()(.playing)
        XCTAssertEqual(view.scripts.count, 1)
        page.webView(view, didStartProvisionalNavigation: nil)
        view.scripts.removeFirst()(["playing": true, "pip": false], nil)
        XCTAssertFalse(page.playing)
        page.updateMediaState()
        view.samples.removeFirst()(.none)
        XCTAssertFalse(page.playing)
    }

    func testPlaybackStartsAndStopsWithoutChangingDocuments() {
        _ = NSApplication.shared
        let view = SampledWebView()
        let page = PageDelegate(window: 992, id: 3, generation: 1, webView: view)
        page.updateMediaState()
        view.samples.removeFirst()(.playing)
        view.scripts.removeFirst()(["playing": true, "pip": false], nil)
        XCTAssertTrue(page.playing)
        page.updateMediaState()
        view.samples.removeFirst()(.paused)
        view.scripts.removeFirst()(["playing": true, "pip": false], nil)
        XCTAssertFalse(page.playing)
    }
    func testSilentNativePlaybackDoesNotShowMusicBadge() {
        _ = NSApplication.shared
        let view = SampledWebView()
        let page = PageDelegate(window: 992, id: 4, generation: 1, webView: view)
        page.playing = true
        page.updateMediaState()
        view.samples.removeFirst()(.playing)
        view.scripts.removeFirst()(["playing": false, "pip": false], nil)
        XCTAssertFalse(page.playing)
    }

}
