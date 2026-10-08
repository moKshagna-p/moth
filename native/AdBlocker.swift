import SwiftUI
import WebKit

struct AdBlockPreferences: Hashable {
    var enabled = true
    var exceptions: [String] = []
    static func isLocal(_ host: String?) -> Bool {
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "[::1]" || host == "::1"
    }
    func blocks(host: String?) -> Bool {
        guard let host else { return false }
        return enabled && !Self.isLocal(host) && !exceptions.contains(host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }
}

// Declarative WebKit filters run in its network engine; no injected request observers.
@MainActor final class AdBlocker: ObservableObject {
    static let shared = AdBlocker()
    @Published private(set) var failure: String?
    private var cache: [AdBlockPreferences: WKContentRuleList] = [:]
    private var pending: [AdBlockPreferences: [(Result<WKContentRuleList?, Error>) -> Void]] = [:]
    static let domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "googletagservices.com",
        "adservice.google.com", "amazon-adsystem.com", "adsystem.com", "adnxs.com", "adsrvr.org",
        "advertising.com", "adform.net", "adform.com", "adroll.com", "adroll.mgr.consensu.org",
        "adsafeprotected.com", "adswizz.com", "adtech.de", "adtechus.com", "adzerk.net",
        "bidswitch.net", "bidr.io", "casalemedia.com", "criteo.com", "criteo.net",
        "exelator.com", "indexww.com", "lijit.com", "media.net", "moatads.com",
        "openx.net", "openx.com", "outbrain.com", "pubmatic.com", "quantserve.com",
        "revcontent.com", "rfihub.com", "rubiconproject.com", "scorecardresearch.com",
        "sharethrough.com", "smartadserver.com", "sovrn.com", "taboola.com", "teads.tv",
        "tremorhub.com", "triplelift.com", "yieldmo.com", "yieldlab.net", "zedo.com"
    ]
    static func filter(for domain: String) -> String {
        "^https?://([a-z0-9-]+\\.)*" + domain.replacingOccurrences(of: ".", with: "\\.") + "[/:]"
    }
    static func encodedRules(exceptions: [String]) throws -> String {
        var rules: [[String: Any]] = domains.map {
            ["trigger": ["url-filter": filter(for: $0), "load-type": ["third-party"]], "action": ["type": "block"]]
        }
        rules.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector":
            "ins.adsbygoogle,[data-ad-slot][data-ad-client],div[id^='google_ads_iframe_'],div[id^='div-gpt-ad'],amp-ad,amp-embed[type='doubleclick']"]])
        // Keep local development and explicit exact-host exceptions untouched, including ad previews.
        var allowed = exceptions.map { host -> String in
            let authority = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
            let escaped = authority.replacingOccurrences(of: ".", with: "\\.")
                .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            return "^https?://" + escaped + "[/:]"
        }
        allowed += ["^https?://([a-z0-9-]+\\.)*localhost[/:]", "^https?://127\\.0\\.0\\.1[/:]", "^https?://\\[::1\\][/:]"]
        rules.append(["trigger": ["url-filter": ".*", "if-top-url": Array(Set(allowed)).sorted()], "action": ["type": "ignore-previous-rules"]])
        return String(decoding: try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]), as: UTF8.self)
    }
    func rules(for preferences: AdBlockPreferences, completion: @escaping (Result<WKContentRuleList?, Error>) -> Void) {
        guard preferences.enabled else { completion(.success(nil)); return }
        if let list = cache[preferences] { completion(.success(list)); return }
        if pending[preferences] != nil { pending[preferences]!.append(completion); return }
        pending[preferences] = [completion]
        do {
            let encoded = try Self.encodedRules(exceptions: preferences.exceptions)
            // One disk identifier avoids accumulating a browsing-host history in the rule store.
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "Moth.BundledAds.v1", encodedContentRuleList: encoded) { [weak self] list, error in
                guard let self else { return }
                let result: Result<WKContentRuleList?, Error>
                if let list {
                    if self.cache.count >= 8 { self.cache.removeAll() }
                    self.cache[preferences] = list; self.failure = nil; result = .success(list)
                } else {
                    let error = error ?? NSError(domain: "Moth.AdBlocker", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebKit could not compile the ad filters."])
                    self.failure = error.localizedDescription; result = .failure(error)
                }
                let callbacks = self.pending.removeValue(forKey: preferences) ?? []
                for callback in callbacks { callback(result) }
            }
        } catch {
            failure = error.localizedDescription
            let callbacks = pending.removeValue(forKey: preferences) ?? []
            for callback in callbacks { callback(.failure(error)) }
        }
    }
}

@MainActor struct AdBlockMenu: View {
    @ObservedObject var model: ChromeModel
    @ObservedObject private var blocker = AdBlocker.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var settings: BrowserSettings { model.snapshot?.settings ?? BrowserSettings() }
    private var host: String? {
        guard let url = model.activeTab.flatMap({ URL(string: $0.url) }), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        return url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    private var active: Bool { settings.adPreferences.blocks(host: host) }
    private var symbol: String {
        if blocker.failure != nil && settings.ad_blocking { return "exclamationmark.shield" }
        return active || (host == nil && settings.ad_blocking) ? "shield.lefthalf.filled" : "shield.slash"
    }
    private var status: String {
        if let failure = blocker.failure, settings.ad_blocking { return "Ad blocker unavailable: " + failure }
        if !settings.ad_blocking { return "Ad blocking off" }
        if AdBlockPreferences.isLocal(host) { return "Ad blocking paused for local development" }
        if host == nil { return "Ad blocking enabled" }
        return active ? "Blocking common ad networks" : "Ad blocking paused on this website"
    }
    var body: some View {
        Menu {
            Text(status)
            if let host, !AdBlockPreferences.isLocal(host) {
                Button(settings.ad_block_exceptions.contains(host) ? "Resume on \(host)" : "Pause on \(host)") {
                    var updated = settings
                    if updated.ad_block_exceptions.contains(host) { updated.ad_block_exceptions.removeAll { $0 == host } }
                    else { updated.ad_block_exceptions.append(host) }
                    save(updated)
                }.disabled(!settings.ad_blocking || model.snapshot?.private_mode == true)
            }
            Button(settings.ad_blocking ? "Turn Ad Blocking Off" : "Turn Ad Blocking On") {
                var updated = settings; updated.ad_blocking.toggle(); save(updated)
            }.disabled(model.snapshot?.private_mode == true)
            if model.snapshot?.private_mode == true { Text("Change ad blocking in a normal window.") }
            Divider()
            Button("Ad Blocking Settings…") { model.send("settings") }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(model.chromeInk)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Ad Blocking · " + status).accessibilityLabel("Ad Blocking").accessibilityValue(status)
    }
    private func save(_ settings: BrowserSettings) {
        guard let data = try? JSONEncoder().encode(settings), let value = try? JSONSerialization.jsonObject(with: data) else { return }
        model.send("set_settings", ["settings": value])
    }
}
