import WebKit

/// YouTube serves player ads from the same hosts as videos. Keep its DOM handling
/// separate from network rules and from the page's JavaScript globals.
@MainActor enum YouTubeAdBlocking {
    static let world = WKContentWorld.world(name: "Moth.YouTubeAds")
    private static let marker = "// Moth.YouTubeAds.v1\n"

    static func install(on view: WKWebView, preferences: AdBlockPreferences) {
        let source = script(preferences: preferences)
        let controller = view.configuration.userContentController
        // Popup configurations can share a controller with their opener. Replace
        // only our script, preserving Wry and all other browser features.
        if !controller.userScripts.contains(where: { $0.source == source }) {
            let others = controller.userScripts.filter { !$0.source.hasPrefix(marker) }
            controller.removeAllUserScripts()
            for script in others { controller.addUserScript(script) }
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: world))
        }
        // Also reconcile an existing document when the user pauses protection.
        view.evaluateJavaScript(source, in: nil, in: world, completionHandler: nil)
    }

    static func script(preferences: AdBlockPreferences) -> String {
        let configuration: [String: Any] = ["enabled": preferences.enabled, "exceptions": preferences.exceptions]
        let data = try! JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        return marker + "(() => { const preferences = " + String(decoding: data, as: UTF8.self) + ";\n" + #"""
            const host = location.hostname.toLowerCase().replace(/\.$/, '');
            if (host !== 'youtube.com' && !host.endsWith('.youtube.com')) return;
            if (globalThis.__mothYouTubeAds) {
                globalThis.__mothYouTubeAds.configure(preferences);
                return;
            }
            let enabled = false, timer = null, observer = null, style = null;
            const selectors = 'ytd-ad-slot-renderer,ytd-display-ad-renderer,ytd-promoted-sparkles-web-renderer,' +
                'ytd-in-feed-ad-layout-renderer,ytd-banner-promo-renderer,ytd-player-legacy-desktop-watch-ads-renderer,' +
                'ytm-ad-slot-renderer,ytm-promoted-sparkles-web-renderer,.ytp-ad-overlay-container';
            const showingAd = player => player &&
                (player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting'));
            function schedule() {
                if (enabled && timer === null) timer = setTimeout(check, 100);
            }
            function check() {
                timer = null;
                if (!enabled || !document.documentElement) return;
                if (!style.isConnected) document.documentElement.append(style);
                const player = document.querySelector('#movie_player, #player .html5-video-player');
                if (!showingAd(player)) return;
                const skip = player.querySelector('.ytp-skip-ad-button,.ytp-ad-skip-button,.ytp-ad-skip-button-modern');
                if (skip && !skip.disabled && skip.getClientRects().length && getComputedStyle(skip).visibility !== 'hidden') {
                    skip.click();
                    // A Skip click can synchronously replace the ad with the video.
                    schedule();
                    return;
                }
                const video = player.querySelector('video');
                // Never seek ordinary content or change the user's volume/speed.
                // Unknown/live durations are left alone until a Skip button appears.
                if (showingAd(player) && video && Number.isFinite(video.duration) && video.duration > 0 &&
                    video.currentTime < video.duration - 0.05) {
                    try { video.currentTime = video.duration; } catch (_) {}
                }
                schedule();
            }
            function configure(next) {
                const active = next.enabled && !next.exceptions.includes(host);
                if (enabled === active) return;
                enabled = active;
                if (!enabled) {
                    if (timer !== null) clearTimeout(timer);
                    timer = null;
                    if (observer) observer.disconnect();
                    observer = null;
                    if (style) style.remove();
                    return;
                }
                style = document.createElement('style');
                style.textContent = selectors + '{display:none!important}';
                observer = new MutationObserver(schedule);
                observer.observe(document, {childList:true, subtree:true, attributes:true,
                    attributeFilter:['class','style','disabled']});
                schedule();
            }
            globalThis.__mothYouTubeAds = {configure};
            document.addEventListener('yt-navigate-finish', schedule);
            window.addEventListener('pageshow', schedule);
            configure(preferences);
        })();
        """#
    }
}
