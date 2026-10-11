import Foundation

/// Local search history and public search-engine completions share literal search intent.
enum SearchSuggestions {
    static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func searchTerm(in address: String) -> String? {
        // Query strings use form encoding: decode '+' as space, but preserve '%2B'.
        guard let url = URLComponents(string: address),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let host = url.host?.lowercased() ?? ""
        let path = url.path
        let supported = (["google.com", "www.google.com", "bing.com", "www.bing.com"].contains(host) && path == "/search")
            || (["duckduckgo.com", "www.duckduckgo.com"].contains(host) && (path.isEmpty || path == "/"))
        guard supported,
              let encoded = url.percentEncodedQuery,
              let form = URLComponents(string: "https://search.invalid/?" + encoded.replacingOccurrences(of: "+", with: "%20")),
              let items = form.queryItems else { return nil }
        let queries = items.filter { $0.name == "q" }
        guard queries.count == 1, let value = queries.first?.value else { return nil }
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 512,
              term.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return term
    }

    static func searchURL(_ term: String, engine: String) -> String {
        let base: String
        switch engine {
        case "duckduckgo": base = "https://duckduckgo.com/"
        case "bing": base = "https://www.bing.com/search"
        default: base = "https://www.google.com/search"
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return base + "?q=" + (term.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }

    static func results(query: String, history: [SavedEntry], engine: String, privateMode: Bool, remote: [String] = []) -> [PaletteResult] {
        let prefix = normalized(query)
        guard !privateMode, !prefix.isEmpty, prefix.count <= 512 else { return [] }
        var seen = Set<String>()
        var results: [PaletteResult] = []
        // Browser history is already newest first. Deduplicate across search providers.
        for entry in history {
            guard let term = searchTerm(in: entry.url) else { continue }
            let key = normalized(term)
            guard key.hasPrefix(prefix), key != prefix, seen.insert(key).inserted else { continue }
            results.append(PaletteResult(id: "search:" + key, title: term, subtitle: "Previous search",
                symbol: "clock.arrow.circlepath", completion: term, command: "open_new_tab",
                values: ["value": searchURL(term, engine: engine)]))
            if results.count == 5 { break }
        }
        for term in remote where results.count < 5 {
            let key = normalized(term)
            guard !key.isEmpty, key != prefix, term.count <= 512,
                  term.rangeOfCharacter(from: .controlCharacters) == nil,
                  seen.insert(key).inserted else { continue }
            results.append(PaletteResult(id: "search:" + key, title: term,
                subtitle: "Search suggestion", symbol: "magnifyingglass",
                completion: term, command: "open_new_tab", values: ["value": searchURL(term, engine: engine)]))
        }
        return results
    }

    static func eligibleQuery(_ query: String) -> String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...512).contains(text.count), text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        // Do not send addresses, credentials, local paths, or URL query strings as predictions.
        let lower = text.lowercased()
        guard !text.contains("://"), !text.contains("@"), !text.contains("/"), !text.contains("\\"),
              !text.contains("?"), !text.contains("="), !lower.hasPrefix("localhost"),
              !lower.hasPrefix("about:"), !lower.hasPrefix("file:"),
              !lower.hasPrefix("data:"), !lower.hasPrefix("javascript:") else { return nil }
        if !text.contains(where: \.isWhitespace), text.contains(".") || text.contains(":") { return nil }
        return text
    }

    static func requestURL(query: String, engine: String) -> URL? {
        guard let query = eligibleQuery(query) else { return nil }
        let base: String
        let name: String
        var items: [URLQueryItem] = []
        switch engine {
        case "duckduckgo":
            base = "https://duckduckgo.com/ac/"; name = "q"
            items.append(URLQueryItem(name: "type", value: "list"))
        case "bing": base = "https://www.bing.com/osjson.aspx"; name = "query"
        default:
            base = "https://www.google.com/complete/search"; name = "q"
            items.append(URLQueryItem(name: "client", value: "chrome"))
        }
        items.append(URLQueryItem(name: name, value: query))
        var url = URLComponents(string: base)!
        url.queryItems = items
        // Some providers decode '+' as a form space, even in a URL query component.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url
    }

    static func parseResponse(_ data: Data, query: String) -> [String] {
        guard data.count <= 65_536,
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any], array.count >= 2,
              let echoed = array[0] as? String, normalized(echoed) == normalized(query),
              let terms = array[1] as? [String] else { return [] }
        var seen = Set([normalized(query)])
        return terms.prefix(50).compactMap { value in
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 512, term.rangeOfCharacter(from: .controlCharacters) == nil,
                  !term.contains("://"), seen.insert(normalized(term)).inserted else { return nil }
            return term
        }.prefix(5).map { $0 }
    }

    static func fetch(query: String, engine: String) async throws -> [String] {
        guard let url = requestURL(query: query, engine: engine) else { return [] }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65_536 else { return [] }
            data.append(byte)
        }
        return parseResponse(data, query: query)
    }
}

/// One cancellable, debounced request per command bar. All state stays on the UI actor.
@MainActor final class LiveSearchSuggestions {
    typealias Fetch = (String, String) async throws -> [String]
    private struct Request: Equatable { let query: String; let engine: String }
    private var request: Request?
    private var task: Task<Void, Never>?
    private let delay: UInt64
    private let fetch: Fetch
    private let receive: ([String]) -> Void

    init(delay: UInt64 = 250_000_000,
         fetch: @escaping Fetch = { try await SearchSuggestions.fetch(query: $0, engine: $1) },
         receive: @escaping ([String]) -> Void) {
        self.delay = delay; self.fetch = fetch; self.receive = receive
    }

    deinit { task?.cancel() }

    func update(query: String, engine: String, enabled: Bool) {
        let next = enabled ? SearchSuggestions.eligibleQuery(query).map { Request(query: $0, engine: engine) } : nil
        guard next != request else { return }
        request = next
        task?.cancel()
        task = nil
        receive([])
        guard let next else { return }
        let delay = delay, fetch = fetch
        task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                let terms = try await fetch(next.query, next.engine)
                try Task.checkCancellation()
                guard self?.request == next else { return }
                self?.receive(terms)
            } catch {
                // Offline, throttled and cancelled requests leave local results usable.
            }
        }
    }
}
