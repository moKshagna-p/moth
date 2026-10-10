import AppKit
import WebKit
import XCTest
@testable import MothNative

@MainActor final class DeveloperTests: XCTestCase {
    func fixtureJSON(appearance: String = "system", hasPhoto: Bool = false, version: Int = 0) -> String {
        #"""
        {"tabs":[{"id":1,"url":"http://localhost:3000/app","title":"Local app","loading":false,"sleeping":false,"pinned":false,"keep_awake":false,"playing":false,"media_suspended":false,"zoom":1,"workspace":1}],
         "bookmarks":[{"url":"https://docs.example.com","title":"API Reference"}],
         "history":[{"url":"https://docs.example.com","title":"API Reference"},{"url":"https://old.example.com","title":"Old Project"}],
         "split_ratio":0.5,"workspaces":[{"id":1,"name":"Personal","project":{"local":"http://localhost:3000","repository":"","docs":"","staging":"https://staging.example.com","production":"","split":true}}],
         "active":1,"active_workspace":1,"private_mode":false,
         "settings":{"search_engine":"google","download_directory":"","restore_session":true,"appearance":"\#(appearance)","site_permissions":{}},
         "bookmarked":false,"can_go_back":false,"can_go_forward":false,"has_photo":\#(hasPhoto),"photo_version":\#(version),"photo_focus_x":50,"photo_focus_y":50}
        """#
    }
    func fixture() throws -> ChromeSnapshot {
        try JSONDecoder().decode(ChromeSnapshot.self, from: Data(fixtureJSON().utf8))
    }
    func testWallpaperContrastStaysReadableWithExplicitPageAppearance() throws {
        _ = NSApplication.shared
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: path) }
        let model = ChromeModel(); model.photoPath = path.path
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        func fill(_ component: UInt8) {
            let pixels = bitmap.bitmapData!
            for y in 0..<32 { for x in 0..<32 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = component; pixels[offset + 1] = component
                pixels[offset + 2] = component; pixels[offset + 3] = 255
            } }
        }
        fill(0)
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
        model.update(fixtureJSON(appearance: "light", hasPhoto: true, version: 1))
        XCTAssertEqual(model.chromeScheme, .dark)
        fill(255)
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
        model.update(fixtureJSON(appearance: "dark", hasPhoto: true, version: 2))
        XCTAssertEqual(model.chromeScheme, .light)
    }
    func testFuzzySearchPreservesOrderAndHandlesUnicode() {
        XCTAssertTrue(PaletteSearch.score("insp", in: "Web Inspector")! > PaletteSearch.score("wip", in: "Web Inspector")!)
        XCTAssertEqual(PaletteSearch.score("cafe", in: "Café"), 1000)
        XCTAssertNil(PaletteSearch.score("abc", in: "cba"))
        XCTAssertNil(PaletteSearch.score("aaaa", in: "aaa"))
        XCTAssertEqual(PaletteSearch.score("", in: ""), 0)
    }
    func testPaletteSearchesAllSourcesAndDeduplicatesSavedLinks() throws {
        let state = try fixture()
        XCTAssertEqual(PaletteSearch.results(snapshot: state, query: "localhost:3000/app", newTab: false).first?.id, "tab:1")
        let saved = PaletteSearch.results(snapshot: state, query: "API Reference", newTab: false)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.command, "open_new_tab")
        XCTAssertEqual(PaletteSearch.results(snapshot: state, query: "Old Project", newTab: false).first?.id, "saved:https://old.example.com")
        XCTAssertEqual(PaletteSearch.results(snapshot: state, query: "Personal", newTab: false).first?.command, "switch_workspace")
        XCTAssertEqual(PaletteSearch.results(snapshot: state, query: "Picture in Picture", newTab: false).first?.command, "picture_in_picture")
        XCTAssertEqual(PaletteSearch.results(snapshot: state, query: "Inspector", newTab: false).first?.shortcut, "⌥⌘I")
        XCTAssertEqual(PaletteSearch.results(snapshot: state, query: "Staging", newTab: false).first?.command, "switch_environment")
    }
    func testPaletteFallbackAndNewTabDoNotLoseNavigation() throws {
        let state = try fixture()
        XCTAssertEqual(PaletteSearch.results(snapshot: state, query: "", newTab: true).first?.command, "open_blank_tab")
        XCTAssertEqual(PaletteSearch.results(snapshot: state, query: "localhost:3000", newTab: true).first?.command, "open_new_tab")
        XCTAssertEqual(PaletteSearch.results(snapshot: state, query: "unique-no-match", newTab: false).first?.command, "open_new_tab")
        XCTAssertFalse(PaletteSearch.results(snapshot: state, query: "", newTab: false).contains { $0.id.hasPrefix("saved:") })
    }
    func testDeveloperAddressKeepsPortsPathsQueriesAndFragments() {
        XCTAssertEqual(developerAddress("http://localhost:3000/api/users?debug=1#result"), "localhost:3000/api/users?debug=1#result")
        XCTAssertEqual(developerAddress("https://example.com/"), "example.com")
        XCTAssertEqual(developerAddress("http://[::1]:8080/api"), "[::1]:8080/api")
        XCTAssertEqual(developerAddress("about:blank"), "about:blank")
    }
    func testWebsiteDataScopeRequiresADomainBoundary() {
        XCTAssertTrue(BrowserFeatures.recordMatches(host: "APP.Example.com.", domain: "example.com"))
        XCTAssertTrue(BrowserFeatures.recordMatches(host: "localhost", domain: "localhost"))
        XCTAssertTrue(BrowserFeatures.recordMatches(host: "127.0.0.1", domain: "127.0.0.1"))
        XCTAssertFalse(BrowserFeatures.recordMatches(host: "notexample.com", domain: "example.com"))
        XCTAssertFalse(BrowserFeatures.recordMatches(host: "example.com", domain: "other.example.com"))
        XCTAssertFalse(BrowserFeatures.recordMatches(host: "example.com", domain: ""))
    }
    func testSplitOverlayMatchesWebViewGutterAndActivePane() {
        let size = CGSize(width: 1220, height: 750)
        let left = DeveloperLayout(size: size, sidebar: 220, split: true, activeRight: false, ratio: 0.5)
        let right = DeveloperLayout(size: size, sidebar: 220, split: true, activeRight: true, ratio: 0.5)
        XCTAssertEqual(left.active, CGRect(x: 220, y: 50, width: 494, height: 694))
        XCTAssertEqual(left.divider, CGRect(x: 714, y: 50, width: 6, height: 694))
        XCTAssertEqual(right.active, CGRect(x: 720, y: 50, width: 494, height: 694))
        XCTAssertEqual(DeveloperLayout(size: size, sidebar: 220, split: false, activeRight: false, ratio: 0.5).active,
                       browserContentFrame(window: size, sidebar: 220))
    }
    func testContentFrameKeepsRightAndBottomBordersWhenSidebarResizes() {
        let size = CGSize(width: 1220, height: 750)
        for sidebar: CGFloat in [180, 220, 360] {
            let content = browserContentFrame(window: size, sidebar: sidebar)
            XCTAssertEqual(content.minX, sidebar)
            XCTAssertEqual(content.minY, 50)
            XCTAssertEqual(size.width - content.maxX, 6)
            XCTAssertEqual(size.height - content.maxY, 6)
        }
    }
    func testPageContainerConfinesLayoutAndCleansUpDetachedPages() {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 1220, height: 750))
        let chrome = NSView(frame: CGRect(x: 0, y: 700, width: 1220, height: 50))
        let page = WKWebView(frame: CGRect(x: 220, y: 0, width: 1000, height: 700))
        root.addSubview(chrome); root.addSubview(page)
        let delegate = PageDelegate(window: 99, id: 1, generation: 1, webView: page)
        BrowserFeatures.pages["99:1"] = delegate
        XCTAssertTrue(page.superview === delegate.container)
        XCTAssertEqual(delegate.container.layer?.cornerRadius, contentCornerRadius)
        XCTAssertEqual(delegate.container.layer?.masksToBounds, true)
        XCTAssertEqual(page.frame, delegate.container.bounds)
        moth_page_layout(99, 1, 723, 50, 497, 700)
        XCTAssertEqual(delegate.container.frame, CGRect(x: 723, y: 0, width: 497, height: 700))
        XCTAssertEqual(page.frame, delegate.container.bounds)
        // Inspector docking may resize this child, but cannot change the chrome or other pane.
        page.frame.size.height = 350
        XCTAssertEqual(chrome.frame, CGRect(x: 0, y: 700, width: 1220, height: 50))
        XCTAssertEqual(delegate.container.frame.width, 497)
        moth_page_visible(99, 1, false)
        let deadline = Date().addingTimeInterval(10)
        while delegate.automaticPresentation.pending, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(delegate.automaticPresentation.pending)
        XCTAssertTrue(delegate.container.isHidden)
        moth_page_visible(99, 1, true)
        XCTAssertFalse(delegate.container.isHidden)
        page.removeFromSuperview()
        BrowserFeatures.prunePages()
        XCTAssertNil(BrowserFeatures.pages["99:1"])
        XCTAssertNil(delegate.container.superview)
    }
}
