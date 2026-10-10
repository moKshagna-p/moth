import AppKit
import WebKit

@MainActor enum PictureInPicture {
    // Include same-origin embeds and open shadow roots without changing page controls.
    private static func elements(_ selector: String) -> String { #"""
    const videos = [];
    function collect(root) {
        videos.push(...root.querySelectorAll('\#(selector)'));
        for (const element of root.querySelectorAll('*')) {
            if (element.shadowRoot) collect(element.shadowRoot);
            if (element.tagName === 'IFRAME') {
                try { if (element.contentDocument) collect(element.contentDocument); } catch (_) {}
            }
        }
    }
    collect(document);
    """# }
    private static let videos = elements("video")
    // WebKit also reports silent players and Web Audio contexts as playing.
    static let mediaStateScript = "(() => {" + elements("audio,video") + #"""
        return {
            playing: videos.some(media => !media.paused && !media.ended && !media.muted && media.volume > 0) ||
                (!videos.length && navigator.mediaSession?.playbackState === 'playing'),
            pip: videos.some(media => media.webkitPresentationMode === 'picture-in-picture' ||
                media.ownerDocument.pictureInPictureElement === media)
        };
    })()
    """#
    static let stateScript = "(() => {" + videos + #"""
        return videos.some(video => video.webkitPresentationMode === 'picture-in-picture' ||
            video.ownerDocument.pictureInPictureElement === video);
    })()
    """#
    static let toggleScript = "(() => {" + videos + #"""
        const current = videos.find(video => video.webkitPresentationMode === 'picture-in-picture');
        if (current) { current.webkitSetPresentationMode('inline'); return 'exited'; }
        const eligible = videos.filter(video => !video.disablePictureInPicture &&
            typeof video.webkitSupportsPresentationMode === 'function' &&
            video.webkitSupportsPresentationMode('picture-in-picture') &&
            typeof video.webkitSetPresentationMode === 'function');
        if (!eligible.length) return videos.length ? 'unsupported' : 'no-video';
        const area = video => {
            const rect = video.getBoundingClientRect();
            const style = video.ownerDocument.defaultView.getComputedStyle(video);
            return style.display === 'none' || style.visibility === 'hidden' ? 0 : rect.width * rect.height;
        };
        eligible.sort((a, b) => Number(!b.paused && !b.ended) - Number(!a.paused && !a.ended) || area(b) - area(a));
        eligible[0].webkitSetPresentationMode('picture-in-picture');
        return 'entered';
    })()
    """#

    static let automaticEntryScript = "(() => {" + videos + #"""
        if (videos.some(video => video.webkitPresentationMode === 'picture-in-picture')) return 'existing';
        const eligible = videos.filter(video => !video.paused && !video.ended && !video.disablePictureInPicture &&
            typeof video.webkitSupportsPresentationMode === 'function' &&
            video.webkitSupportsPresentationMode('picture-in-picture') &&
            typeof video.webkitSetPresentationMode === 'function');
        const area = video => {
            const rect = video.getBoundingClientRect();
            const style = video.ownerDocument.defaultView.getComputedStyle(video);
            return style.display === 'none' || style.visibility === 'hidden' ? 0 : rect.width * rect.height;
        };
        eligible.sort((a, b) => area(b) - area(a));
        const video = eligible.find(video => area(video) > 0);
        if (!video) return 'unavailable';
        video.webkitSetPresentationMode('picture-in-picture');
        return 'entered';
    })()
    """#
    static let automaticExitScript = "(() => {" + videos + #"""
        for (const video of videos) {
            if (video.webkitPresentationMode === 'picture-in-picture') video.webkitSetPresentationMode('inline');
        }
        return 'exited';
    })()
    """#

    static func toggle(_ page: PageDelegate?) {
        guard let page, let view = page.webView else { return }
        page.automaticPresentation.manualOverride()
        // The frame/content-world API preserves the native menu action's user gesture.
        view.evaluateJavaScript(toggleScript, in: nil, in: .page) { [weak page, weak view] result in
            guard let view, let page, page.webView === view else { return }
            let message: String?
            switch result {
            case .success(let value):
                switch value as? String {
                case "entered", "exited": page.updateMediaState(); return
                case "no-video": message = "Open a page with a video, start playback, then try again. Embedded videos may need to be opened on their own website."
                default: message = "Start the video and try again. This video or website may not allow picture in picture."
                }
            case .failure: message = "This video could not enter picture in picture. Start playback and try again."
            }
            guard let window = view.window else { return }
            let alert = NSAlert(); alert.messageText = "Picture in Picture"; alert.informativeText = message ?? ""
            alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: window)
        }
    }
}

// Automatic ownership is separate from manually opened PiP. Only foreground
// transitions trigger entry, so dismissing the player does not reopen it on a timer.
struct AutomaticPictureInPicture {
    enum Action: Equatable { case none, enter, exit }
    private(set) var foreground = true
    private(set) var pending = false
    private(set) var ownsPresentation = false
    private var manual = false

    mutating func update(foreground: Bool) -> Action {
        guard self.foreground != foreground else { return .none }
        self.foreground = foreground
        guard !pending else { return .none }
        if foreground { return ownsPresentation ? begin(.exit) : .none }
        manual = false
        return begin(.enter)
    }
    mutating func completed(_ action: Action, entered: Bool) -> Action {
        pending = false
        ownsPresentation = action == .enter && entered && !manual
        if foreground && ownsPresentation { return begin(.exit) }
        if action == .exit && !foreground && !manual { return begin(.enter) }
        return .none
    }
    mutating func manualOverride() { manual = true; ownsPresentation = false }
    mutating func dismissed() { ownsPresentation = false }
    private mutating func begin(_ action: Action) -> Action { pending = true; return action }
}
