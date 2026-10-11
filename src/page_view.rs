//! Tabs can own either a Wry page or a live WebKit auxiliary page moved into Moth.
pub(crate) enum PageView {
    Wry(wry::WebView),
    #[cfg(target_os = "macos")]
    Adopted {
        window: u64,
        id: u64,
    },
}

impl From<wry::WebView> for PageView {
    fn from(view: wry::WebView) -> Self {
        Self::Wry(view)
    }
}

impl PageView {
    #[cfg(target_os = "macos")]
    fn native(&self, operation: &str, argument: &str) -> wry::Result<String> {
        let Self::Adopted { window, id } = self else {
            unreachable!()
        };
        crate::native_chrome::page_operation(*window, *id, operation, argument)
            .ok_or_else(|| std::io::Error::other("The page is no longer available").into())
    }
    pub fn load_url(&self, url: &str) -> wry::Result<()> {
        match self {
            Self::Wry(view) => view.load_url(url),
            #[cfg(target_os = "macos")]
            Self::Adopted { .. } => self.native("navigate", url).map(|_| ()),
        }
    }
    pub fn zoom(&self, scale: f64) -> wry::Result<()> {
        match self {
            Self::Wry(view) => view.zoom(scale),
            #[cfg(target_os = "macos")]
            Self::Adopted { .. } => self.native("zoom", &scale.to_string()).map(|_| ()),
        }
    }
    pub fn evaluate_script_with_callback(
        &self,
        script: &str,
        callback: impl Fn(String) + Send + 'static,
    ) -> wry::Result<()> {
        match self {
            Self::Wry(view) => view.evaluate_script_with_callback(script, callback),
            #[cfg(target_os = "macos")]
            Self::Adopted { window, id } => {
                crate::native_chrome::evaluate_page(*window, *id, script, callback)
            }
        }
    }
    pub fn open_devtools(&self) {
        match self {
            Self::Wry(view) => view.open_devtools(),
            #[cfg(target_os = "macos")]
            Self::Adopted { .. } => {
                let _ = self.native("inspect", "");
            }
        }
    }
    pub fn url(&self) -> wry::Result<String> {
        match self {
            Self::Wry(view) => view.url(),
            #[cfg(target_os = "macos")]
            Self::Adopted { .. } => self.native("url", ""),
        }
    }
    pub fn can_go_back(&self) -> wry::Result<bool> {
        match self {
            Self::Wry(view) => view.can_go_back(),
            #[cfg(target_os = "macos")]
            Self::Adopted { .. } => self.native("can_go_back", "").map(|s| s == "true"),
        }
    }
    pub fn can_go_forward(&self) -> wry::Result<bool> {
        match self {
            Self::Wry(view) => view.can_go_forward(),
            #[cfg(target_os = "macos")]
            Self::Adopted { .. } => self.native("can_go_forward", "").map(|s| s == "true"),
        }
    }
    #[cfg(not(target_os = "macos"))]
    pub fn set_bounds(&self, bounds: wry::Rect) -> wry::Result<()> {
        let Self::Wry(view) = self;
        view.set_bounds(bounds)
    }
    #[cfg(not(target_os = "macos"))]
    pub fn set_visible(&self, visible: bool) -> wry::Result<()> {
        let Self::Wry(view) = self;
        view.set_visible(visible)
    }
}
macro_rules! page_action {
    ($($name:ident),*) => { impl PageView { $(
        pub fn $name(&self) -> wry::Result<()> {
            match self {
                Self::Wry(view) => view.$name(),
                #[cfg(target_os = "macos")]
                Self::Adopted { .. } => self.native(stringify!($name), "").map(|_| ()),
            }
        }
    )* } };
}
page_action!(go_back, go_forward, reload, print);

impl Drop for PageView {
    fn drop(&mut self) {
        #[cfg(target_os = "macos")]
        if let Self::Adopted { window, id } = self {
            let _ = crate::native_chrome::page_operation(*window, *id, "close", "");
        }
    }
}
