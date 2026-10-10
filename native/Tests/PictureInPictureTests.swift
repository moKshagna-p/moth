import AppKit
import WebKit
import XCTest
@testable import MothNative

@MainActor final class PictureInPictureTests: XCTestCase {
    private func evaluate(_ script: String, in view: WKWebView) -> Any? {
        var done = false; var result: Any?
        view.evaluateJavaScript(script, in: nil, in: .page) { response in
            switch response {
            case .success(let value): result = value
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            done = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !done, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(done); return result
    }
    private func fixture() -> WKWebView {
        _ = NSApplication.shared
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.loadHTMLString("<html><body><video id='large' width='640' height='360'></video><video id='small' width='160' height='90'></video></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while view.isLoading, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(view.isLoading)
        _ = evaluate(#"""
            window.selected = '';
            for (const video of document.querySelectorAll('video')) {
                video.webkitSupportsPresentationMode = () => true;
                Object.defineProperty(video, 'webkitPresentationMode', { value: 'inline', writable: true });
                video.webkitSetPresentationMode = mode => { video.webkitPresentationMode = mode; selected = video.id; };
            }
            true
        """#, in: view)
        return view
    }
    func testChoosesPlayingVideoAndTogglesBackToInline() {
        let view = fixture()
        _ = evaluate("Object.defineProperty(small, 'paused', {value: false}); true", in: view)
        XCTAssertEqual(evaluate(PictureInPicture.toggleScript, in: view) as? String, "entered")
        XCTAssertEqual(evaluate("selected", in: view) as? String, "small")
        XCTAssertEqual(evaluate(PictureInPicture.stateScript, in: view) as? Bool, true)
        XCTAssertEqual(evaluate(PictureInPicture.toggleScript, in: view) as? String, "exited")
        XCTAssertEqual(evaluate(PictureInPicture.stateScript, in: view) as? Bool, false)
    }
    func testChoosesLargestVideoAndRespectsDisabledVideos() {
        let view = fixture()
        XCTAssertEqual(evaluate(PictureInPicture.toggleScript, in: view) as? String, "entered")
        XCTAssertEqual(evaluate("selected", in: view) as? String, "large")
        _ = evaluate(PictureInPicture.toggleScript, in: view)
        _ = evaluate("large.disablePictureInPicture = true; true", in: view)
        XCTAssertEqual(evaluate(PictureInPicture.toggleScript, in: view) as? String, "entered")
        XCTAssertEqual(evaluate("selected", in: view) as? String, "small")
        _ = evaluate(PictureInPicture.toggleScript, in: view)
        _ = evaluate("small.webkitSupportsPresentationMode = () => false; true", in: view)
        XCTAssertEqual(evaluate(PictureInPicture.toggleScript, in: view) as? String, "unsupported")
        _ = evaluate("document.body.replaceChildren(); true", in: view)
        XCTAssertEqual(evaluate(PictureInPicture.toggleScript, in: view) as? String, "no-video")
    }
    func testFindsVideosInsideOpenShadowRoots() {
        let view = fixture()
        _ = evaluate("const root = document.createElement('div'); document.body.append(root); root.attachShadow({mode:'open'}).append(large); small.remove(); true", in: view)
        XCTAssertEqual(evaluate(PictureInPicture.toggleScript, in: view) as? String, "entered")
        XCTAssertEqual(evaluate(PictureInPicture.stateScript, in: view) as? Bool, true)
    }


    func testMusicBadgeRequiresUnmutedPlaybackOrExplicitMediaSession() {
        let view = fixture()
        func playing() -> Bool? { (evaluate(PictureInPicture.mediaStateScript, in: view) as? [String: Bool])?["playing"] }
        XCTAssertEqual(playing(), false)
        _ = evaluate("Object.defineProperty(small, 'paused', {value: false, configurable: true}); small.muted = true; navigator.mediaSession.playbackState = 'playing'; true", in: view)
        XCTAssertEqual(playing(), false)
        _ = evaluate("small.muted = false; small.volume = 0; true", in: view)
        XCTAssertEqual(playing(), false)
        _ = evaluate("small.volume = 1; true", in: view)
        XCTAssertEqual(playing(), true)
        _ = evaluate("document.body.replaceChildren(); navigator.mediaSession.playbackState = 'none'; true", in: view)
        XCTAssertEqual(playing(), false)
        _ = evaluate("const audio = document.createElement('audio'); document.body.append(audio); Object.defineProperty(audio, 'paused', {value:false}); true", in: view)
        XCTAssertEqual(playing(), true)
        _ = evaluate("const host = document.createElement('div'); document.body.append(host); host.attachShadow({mode:'open'}).append(audio); true", in: view)
        XCTAssertEqual(playing(), true)
        _ = evaluate("document.body.replaceChildren(); navigator.mediaSession.playbackState = 'playing'; true", in: view)
        XCTAssertEqual(playing(), true)
    }

    func testAutomaticEntryRequiresPlayingVisibleVideoAndPreservesManualPlayer() {
        let view = fixture()
        XCTAssertEqual(evaluate(PictureInPicture.automaticEntryScript, in: view) as? String, "unavailable")
        _ = evaluate("Object.defineProperty(small, 'paused', {value: false}); small.style.display = 'none'; true", in: view)
        XCTAssertEqual(evaluate(PictureInPicture.automaticEntryScript, in: view) as? String, "unavailable")
        _ = evaluate("small.style.display = ''; true", in: view)
        XCTAssertEqual(evaluate(PictureInPicture.automaticEntryScript, in: view) as? String, "entered")
        XCTAssertEqual(evaluate("selected", in: view) as? String, "small")
        XCTAssertEqual(evaluate(PictureInPicture.automaticEntryScript, in: view) as? String, "existing")
        XCTAssertEqual(evaluate(PictureInPicture.automaticExitScript, in: view) as? String, "exited")
        XCTAssertEqual(evaluate(PictureInPicture.stateScript, in: view) as? Bool, false)
        _ = evaluate("document.body.replaceChildren(document.createElement('audio')); true", in: view)
        XCTAssertEqual(evaluate(PictureInPicture.automaticEntryScript, in: view) as? String, "unavailable")
    }
    func testAutomaticLifecycleReturnsToPageAndDoesNotReopenAfterDismissal() {
        var state = AutomaticPictureInPicture()
        XCTAssertEqual(state.update(foreground: false), .enter)
        XCTAssertEqual(state.completed(.enter, entered: true), .none)
        XCTAssertTrue(state.ownsPresentation)
        XCTAssertEqual(state.update(foreground: false), .none)
        XCTAssertEqual(state.update(foreground: true), .exit)
        XCTAssertEqual(state.completed(.exit, entered: false), .none)
        XCTAssertFalse(state.ownsPresentation)
        XCTAssertEqual(state.update(foreground: false), .enter)
        _ = state.completed(.enter, entered: true)
        state.dismissed()
        XCTAssertEqual(state.update(foreground: false), .none)
        XCTAssertEqual(state.update(foreground: true), .none)
        XCTAssertEqual(state.update(foreground: false), .enter)
    }
    func testReturnDuringPendingEntryAndManualOverride() {
        var state = AutomaticPictureInPicture()
        XCTAssertEqual(state.update(foreground: false), .enter)
        XCTAssertEqual(state.update(foreground: true), .none)
        XCTAssertEqual(state.completed(.enter, entered: true), .exit)
        _ = state.completed(.exit, entered: false)
        XCTAssertEqual(state.update(foreground: false), .enter)
        state.manualOverride()
        XCTAssertEqual(state.completed(.enter, entered: true), .none)
        XCTAssertEqual(state.update(foreground: true), .none)
        XCTAssertFalse(state.ownsPresentation)
        XCTAssertEqual(state.update(foreground: false), .enter)
        // A player that already exists belongs to the user.
        XCTAssertEqual(state.completed(.enter, entered: false), .none)
        XCTAssertEqual(state.update(foreground: true), .none)
    }

    func testLeavingAgainDuringPendingExitReenters() {
        var state = AutomaticPictureInPicture()
        _ = state.update(foreground: false)
        _ = state.completed(.enter, entered: true)
        XCTAssertEqual(state.update(foreground: true), .exit)
        XCTAssertEqual(state.update(foreground: false), .none)
        XCTAssertEqual(state.completed(.exit, entered: false), .enter)
        XCTAssertEqual(state.completed(.enter, entered: true), .none)
        XCTAssertTrue(state.ownsPresentation)
    }
    func testWindowFocusNotificationsEnterAndRestorePlayingVideo() {
        let view = fixture()
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: view.frame)
        window.contentView?.addSubview(view)
        let page = PageDelegate(window: 994, id: 1, generation: 1, webView: view)
        _ = evaluate("Object.defineProperty(small, 'paused', {value: false}); true", in: view)
        func waitForPresentation() {
            let deadline = Date().addingTimeInterval(10)
            while page.automaticPresentation.pending, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertFalse(page.automaticPresentation.pending)
        }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        waitForPresentation()
        XCTAssertTrue(page.pictureInPicture)
        XCTAssertTrue(page.automaticPresentation.ownsPresentation)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        waitForPresentation()
        XCTAssertFalse(page.pictureInPicture)
        XCTAssertFalse(page.automaticPresentation.ownsPresentation)
        XCTAssertEqual(evaluate(PictureInPicture.stateScript, in: view) as? Bool, false)
        window.close()
    }

    func testInactivePictureInPictureRetainsItsWebView() {
        let view = fixture()
        let parent = NSView(frame: view.frame)
        parent.addSubview(view)
        let page = PageDelegate(window: 993, id: 1, generation: 1, webView: view)
        page.pictureInPicture = true
        page.setVisible(false)
        XCTAssertFalse(view.isHidden)
        XCTAssertFalse(page.container.isHidden)
        XCTAssertEqual(page.container.alphaValue, 0)
        XCTAssertTrue(view.superview === page.container)
        XCTAssertTrue(page.container.superview === parent)
        XCTAssertFalse(page.visible)
        XCTAssertNil(page.container.hitTest(CGPoint(x: 20, y: 20)))
        page.setVisible(true)
        XCTAssertEqual(page.container.alphaValue, 1)
        page.pictureInPicture = false
        page.setVisible(false)
        let deadline = Date().addingTimeInterval(10)
        while page.automaticPresentation.pending, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(page.automaticPresentation.pending)
        XCTAssertTrue(view.isHidden)
        XCTAssertTrue(page.container.isHidden)
    }
}
