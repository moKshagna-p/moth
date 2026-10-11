import Foundation

/// Search completions use existing history only; typing never starts a network request.
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

    static func results(query: String, history: [SavedEntry], engine: String, privateMode: Bool) -> [PaletteResult] {
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
        return results
    }
}
