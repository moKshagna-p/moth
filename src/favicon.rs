use serde::Deserialize;

pub(crate) const SCRIPT: &str = include_str!("../ui/favicon.js");

#[derive(Debug, Deserialize)]
pub(crate) struct PageIcon {
    pub page: String,
    pub icon: Option<String>,
}

// Page-provided metadata must never make native chrome load local files or
// custom URL schemes. Fetch icons directly, without a third-party icon service.
pub(crate) fn web_icon(value: &str) -> Option<String> {
    if value.len() > 8192 {
        return None;
    }
    let url = url::Url::parse(value).ok()?;
    (matches!(url.scheme(), "http" | "https")
        && url.host_str().is_some()
        && url.username().is_empty()
        && url.password().is_none())
    .then(|| url.into())
}

pub(crate) fn fallback(page: &str) -> Option<String> {
    let page = web_icon(page)?;
    url::Url::parse(&page)
        .ok()?
        .join("/favicon.ico")
        .ok()
        .map(Into::into)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_web_icons_are_accepted() {
        assert!(web_icon("https://cdn.example.com/icon.png").is_some());
        for value in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,x",
            "moth-photo://localhost/photo",
            "https://user:pass@example.com/icon",
        ] {
            assert_eq!(web_icon(value), None);
        }
    }

    #[test]
    fn fallback_uses_origin_without_page_query_or_fragment() {
        assert_eq!(
            fallback("https://example.com:8443/a/b?q=1#part"),
            Some("https://example.com:8443/favicon.ico".into())
        );
        assert_eq!(fallback("about:blank"), None);
    }
}
