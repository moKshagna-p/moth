use url::Url;

pub fn resolve_address(input: &str) -> String {
    let input = input.trim();
    if input.is_empty() {
        return "about:blank".into();
    }
    if let Ok(url) = Url::parse(input) {
        if matches!(url.scheme(), "http" | "https" | "file" | "about") {
            return url.into();
        }
    }
    let looks_local = input == "localhost"
        || input.starts_with("localhost:")
        || input.starts_with("127.0.0.1")
        || input.starts_with("[::1]");
    if !input.contains(char::is_whitespace) && (input.contains('.') || looks_local) {
        let prefix = if looks_local { "http://" } else { "https://" };
        let candidate = format!("{prefix}{input}");
        if Url::parse(&candidate).is_ok() {
            return candidate;
        }
    }
    let query: String = url::form_urlencoded::Serializer::new(String::new())
        .append_pair("q", input)
        .finish();
    format!("https://www.google.com/search?{query}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn address_resolves_sites_local_hosts_and_searches() {
        assert_eq!(resolve_address("example.com"), "https://example.com");
        assert_eq!(resolve_address("localhost:3000"), "http://localhost:3000");
        assert_eq!(
            resolve_address("rust language"),
            "https://www.google.com/search?q=rust+language"
        );
        assert_eq!(
            resolve_address("javascript:alert(1)"),
            "https://www.google.com/search?q=javascript%3Aalert%281%29"
        );
    }
}
