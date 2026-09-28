use crate::{
    address::resolve_address,
    data::{BrowserData, Entry, SessionTab, Workspace},
    downloads::unique_download_path,
    protocol::{BrowserEvent, Command},
};
#[cfg(target_os = "macos")]
use muda::MenuEvent;
use serde::Serialize;
use std::{
    borrow::Cow,
    cmp::Reverse,
    fs,
    path::PathBuf,
    time::{Duration, Instant},
};
use tao::{
    dpi::{LogicalPosition, LogicalSize},
    event_loop::EventLoopProxy,
    window::Window,
};
use wry::{http::Response, NewWindowResponse, PageLoadEvent, Rect, WebView, WebViewBuilder};

const SIDEBAR_WIDTH: f64 = 220.0;
const TOOLBAR_HEIGHT: f64 = 50.0;
const MAX_LIVE_TABS: usize = 8;
const IDLE_TAB_AGE: Duration = Duration::from_secs(15 * 60);

fn shortcut_tab_index(index: usize, count: usize) -> Option<usize> {
    if count == 0 {
        None
    } else if index == 8 {
        Some(count - 1)
    } else {
        (index < count).then_some(index)
    }
}

fn adjacent_tab_index(current: usize, count: usize, next: bool) -> Option<usize> {
    if count == 0 || current >= count {
        None
    } else if next {
        Some((current + 1) % count)
    } else {
        Some((current + count - 1) % count)
    }
}

fn eviction_score(idle: Duration, activations: u32) -> u128 {
    idle.as_millis() / u128::from(activations.clamp(1, 4))
}

struct Tab {
    id: u64,
    workspace: u64,
    view: Option<WebView>,
    visible: bool,
    generation: u64,
    last_used: Instant,
    activations: u32,
    url: String,
    title: String,
    favicon: Option<String>,
    loading: bool,
    site_color: Option<[u8; 3]>,
}

fn record_tab_switch(tabs: &mut [Tab], previous: u64, next: u64, now: Instant) {
    if previous == next {
        return;
    }
    for tab in tabs {
        if tab.id == previous || tab.id == next {
            // Time spent reading the foreground tab is not idle time.
            tab.last_used = now;
        }
        if tab.id == next {
            tab.activations = tab.activations.saturating_add(1);
        }
    }
}

#[derive(Serialize)]
struct TabState<'a> {
    id: u64,
    workspace: u64,
    url: &'a str,
    title: &'a str,
    favicon: Option<&'a str>,
    loading: bool,
    sleeping: bool,
}

#[derive(Serialize)]
struct ShellState<'a> {
    tabs: Vec<TabState<'a>>,
    workspaces: &'a [Workspace],
    active: u64,
    active_workspace: u64,
    bookmarks: &'a [Entry],
    history: &'a [Entry],
    downloads: &'a [Download],
    panel: Option<&'a str>,
    bookmarked: bool,
    can_go_back: bool,
    can_go_forward: bool,
    has_photo: bool,
    photo_version: u64,
    photo_focus_x: u8,
    photo_focus_y: u8,
    sidebar_width: u16,
    site_color: Option<[u8; 3]>,
}

#[derive(Serialize)]
struct Download {
    url: String,
    filename: String,
    complete: bool,
    success: bool,
}

pub(crate) struct Browser {
    window: Window,
    shell: WebView,
    tabs: Vec<Tab>,
    closed_tabs: Vec<String>,
    active: u64,
    active_workspace: u64,
    next_tab_id: u64,
    panel: Option<String>,
    data: BrowserData,
    data_path: PathBuf,
    photo_path: PathBuf,
    photo_version: u64,
    downloads: Vec<Download>,
    save_due: Option<Instant>,
    last_size: Option<(f64, f64)>,
    shell_visible: Option<bool>,
    proxy: EventLoopProxy<BrowserEvent>,
}

impl Browser {
    pub(crate) fn new(window: Window, proxy: EventLoopProxy<BrowserEvent>) -> wry::Result<Self> {
        let data_path = std::env::var_os("MOTH_DATA_DIR")
            .map(PathBuf::from)
            .or_else(dirs::data_dir)
            .unwrap_or_else(|| PathBuf::from("."))
            .join("Moth")
            .join("state.json");
        let photo_path = data_path.with_file_name("new-tab-photo");
        let protocol_photo_path = photo_path.clone();
        let shell_proxy = proxy.clone();
        let shell_html = include_str!("../ui/shell.html")
            .replace("/* MOTH_CSS */", include_str!("../ui/shell.css"))
            .replace("/* MOTH_JS */", include_str!("../ui/shell.js"));
        let shell = WebViewBuilder::new()
            .with_html(shell_html)
            .with_custom_protocol("moth-photo".into(), move |_, request| {
                if request.uri().path() != "/photo" {
                    return Response::builder()
                        .status(404)
                        .body(Cow::Borrowed(b"Not found" as &[u8]))
                        .unwrap();
                }
                match fs::read(&protocol_photo_path) {
                    Ok(bytes) if bytes.len() <= 30 * 1024 * 1024 => {
                        let mime = photo_mime(&bytes).unwrap_or("application/octet-stream");
                        Response::builder()
                            .header("Content-Type", mime)
                            .header("Cache-Control", "no-store")
                            .body(Cow::Owned(bytes))
                            .unwrap()
                    }
                    _ => Response::builder()
                        .status(404)
                        .body(Cow::Borrowed(b"No photo" as &[u8]))
                        .unwrap(),
                }
            })
            .with_bounds(rect(SIDEBAR_WIDTH, TOOLBAR_HEIGHT, 748.0, 700.0))
            .with_ipc_handler(move |request| {
                if let Ok(command) = serde_json::from_str::<Command>(request.body()) {
                    let _ = shell_proxy.send_event(BrowserEvent::Command(command));
                }
            })
            .build_as_child(&window)?;

        let data = BrowserData::load(&data_path);
        let restored_tabs = data.session_tabs.clone();
        let active_tab_index = data.active_tab_index;
        let active_workspace = data.active_workspace;
        #[cfg(target_os = "macos")]
        crate::native_chrome::install(&window, proxy.clone(), &photo_path);
        let mut browser = Self {
            window,
            shell,
            tabs: Vec::new(),
            closed_tabs: Vec::new(),
            active: 0,
            active_workspace,
            next_tab_id: 1,
            panel: None,
            data,
            data_path,
            photo_version: u64::from(photo_path.exists()),
            photo_path,
            downloads: Vec::new(),
            save_due: None,
            last_size: None,
            shell_visible: None,
            proxy,
        };
        browser.resize();
        let mut restored_active = None;
        for (index, tab) in restored_tabs.into_iter().enumerate() {
            if browser
                .data
                .workspaces
                .iter()
                .any(|space| space.id == tab.workspace)
            {
                browser.restore_tab(tab);
                if index == active_tab_index {
                    restored_active = browser.tabs.last().map(|tab| tab.id);
                }
            }
        }
        if let Some(id) = restored_active
            .filter(|id| {
                browser
                    .tabs
                    .iter()
                    .any(|tab| tab.id == *id && tab.workspace == active_workspace)
            })
            .or_else(|| {
                browser
                    .tabs
                    .iter()
                    .find(|tab| tab.workspace == active_workspace)
                    .map(|tab| tab.id)
            })
        {
            browser.activate_tab(id)?;
        } else {
            browser.new_tab("about:blank")?;
        }
        browser.resize();
        browser.refresh();
        browser.save();
        Ok(browser)
    }

    fn size(&self) -> LogicalSize<f64> {
        self.window
            .inner_size()
            .to_logical(self.window.scale_factor())
    }

    pub(crate) fn resize(&mut self) {
        let size = self.size();
        let show_shell_page = self.panel.is_some()
            || self
                .active_tab()
                .is_some_and(|tab| tab.url == "about:blank");
        let content_width = (size.width - self.data.sidebar_width as f64).max(1.0);
        let content_height = (size.height - TOOLBAR_HEIGHT).max(1.0);
        if self.last_size != Some((size.width, size.height)) {
            let bounds = rect(self.data.sidebar_width as f64, TOOLBAR_HEIGHT, content_width, content_height);
            let _ = self.shell.set_bounds(bounds);
            #[cfg(target_os = "macos")]
            crate::native_chrome::resize(size.width, size.height);
            for tab in &self.tabs {
                if let Some(view) = &tab.view {
                    let _ = view.set_bounds(bounds);
                }
            }
            self.last_size = Some((size.width, size.height));
        }
        if self.shell_visible != Some(show_shell_page) {
            let _ = self.shell.set_visible(show_shell_page);
            self.shell_visible = Some(show_shell_page);
        }
        for tab in &mut self.tabs {
            let visible = tab.id == self.active && !show_shell_page && tab.view.is_some();
            if tab.visible != visible {
                if let Some(view) = &tab.view {
                    let _ = view.set_visible(visible);
                }
                tab.visible = visible;
            }
        }
    }

    fn new_tab(&mut self, url: &str) -> wry::Result<()> {
        self.new_tab_in_workspace(url, self.active_workspace)
    }

    fn new_tab_in_workspace(&mut self, url: &str, workspace: u64) -> wry::Result<()> {
        let id = self.next_tab_id;
        self.next_tab_id += 1;
        let view = if url == "about:blank" {
            None
        } else {
            Some(self.build_view(id, 1, url)?)
        };
        self.tabs.push(Tab {
            id,
            workspace,
            view,
            visible: false,
            generation: 1,
            last_used: Instant::now(),
            activations: 0,
            url: url.into(),
            title: "New tab".into(),
            favicon: crate::favicon::fallback(url),
            loading: url != "about:blank",
            site_color: None,
        });
        record_tab_switch(&mut self.tabs, self.active, id, Instant::now());
        self.active = id;
        self.panel = None;
        self.resize();
        self.reap_tabs();
        self.refresh();
        Ok(())
    }

    fn restore_tab(&mut self, session: SessionTab) {
        let id = self.next_tab_id;
        self.next_tab_id += 1;
        let title = if session.url == "about:blank" {
            "New tab".into()
        } else {
            self.data
                .history
                .iter()
                .find(|entry| entry.url == session.url)
                .map(|entry| entry.title.clone())
                .unwrap_or_else(|| session.url.clone())
        };
        self.tabs.push(Tab {
            id,
            workspace: session.workspace,
            view: None,
            visible: false,
            generation: 0,
            last_used: Instant::now(),
            activations: 0,
            favicon: crate::favicon::fallback(&session.url),
            url: session.url,
            title,
            loading: false,
            site_color: None,
        });
    }

    fn sample_site_color(&self, id: u64, generation: u64) {
        let Some(tab) = self.tabs.iter().find(|tab| tab.id == id && tab.generation == generation
            && !tab.loading && (tab.url.starts_with("https://") || tab.url.starts_with("http://"))) else { return };
        let Some(view) = &tab.view else { return };
        let proxy = self.proxy.clone();
        let _ = view.evaluate_script_with_callback(include_str!("../ui/site-theme.js"), move |result| {
            #[derive(serde::Deserialize)]
            struct Sample { url: String, color: [u8; 3] }
            if let Ok(sample) = serde_json::from_str::<Sample>(&result) {
                let _ = proxy.send_event(BrowserEvent::SiteColor(id, generation, sample.url, sample.color));
            }
        });
    }

    fn build_view(&self, id: u64, generation: u64, url: &str) -> wry::Result<WebView> {
        let size = self.size();
        let load_proxy = self.proxy.clone();
        let title_proxy = self.proxy.clone();
        let window_proxy = self.proxy.clone();
        let download_proxy = self.proxy.clone();
        let completed_proxy = self.proxy.clone();
        WebViewBuilder::new()
            // Bare WKWebView omits Safari's product tokens; Google consequently
            // serves its simplified results page without the full image UI.
            .with_user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15")
            .with_url(url)
            .with_visible(false)
            .with_bounds(rect(
                self.data.sidebar_width as f64,
                TOOLBAR_HEIGHT,
                (size.width - self.data.sidebar_width as f64).max(1.0),
                (size.height - TOOLBAR_HEIGHT).max(1.0),
            ))
            .with_on_page_load_handler(move |event, url| {
                let message = match event {
                    PageLoadEvent::Started => BrowserEvent::PageStarted(id, generation, url),
                    PageLoadEvent::Finished => BrowserEvent::PageFinished(id, generation, url),
                };
                let _ = load_proxy.send_event(message);
            })
            .with_document_title_changed_handler(move |title| {
                let _ = title_proxy.send_event(BrowserEvent::TitleChanged(id, generation, title));
            })
            .with_new_window_req_handler(move |url, _| {
                let _ = window_proxy.send_event(BrowserEvent::OpenTab(url));
                NewWindowResponse::Deny
            })
            .with_download_started_handler(move |url, path| {
                let download_dir = dirs::download_dir().unwrap_or_else(|| PathBuf::from("."));
                let filename = path
                    .file_name()
                    .and_then(|name| name.to_str())
                    .map(str::to_owned)
                    .or_else(|| {
                        url::Url::parse(&url)
                            .ok()
                            .and_then(|url| url.path_segments()?.next_back().map(str::to_owned))
                    })
                    .filter(|name| !name.is_empty())
                    .unwrap_or_else(|| "download".into());
                let unique = unique_download_path(&download_dir, &filename);
                *path = unique.clone();
                let _ = download_proxy.send_event(BrowserEvent::DownloadStarted(
                    url,
                    unique.to_string_lossy().into_owned(),
                ));
                true
            })
            .with_download_completed_handler(move |url, _, success| {
                let _ = completed_proxy.send_event(BrowserEvent::DownloadFinished(url, success));
            })
            .build_as_child(&self.window)
    }

    fn active_tab(&self) -> Option<&Tab> {
        self.tabs.iter().find(|tab| tab.id == self.active)
    }

    fn activate_tab(&mut self, id: u64) -> wry::Result<()> {
        let Some(index) = self.tabs.iter().position(|tab| tab.id == id) else {
            return Ok(());
        };
        if self.tabs[index].view.is_none() && self.tabs[index].url != "about:blank" {
            let generation = self.tabs[index].generation + 1;
            let view = self.build_view(id, generation, &self.tabs[index].url)?;
            self.tabs[index].view = Some(view);
            self.tabs[index].generation = generation;
            self.tabs[index].loading = true;
        }
        record_tab_switch(&mut self.tabs, self.active, id, Instant::now());
        self.active = id;
        self.active_workspace = self.tabs[index].workspace;
        self.sample_site_color(id, self.tabs[index].generation);
        self.panel = None;
        self.resize();
        self.reap_tabs();
        self.refresh();
        Ok(())
    }

    fn switch_tab(&mut self, id: u64) {
        if let Err(error) = self.activate_tab(id) {
            eprintln!("Cannot switch tab: {error}");
        }
    }

    fn navigate_active(&mut self, url: String) {
        let Some(index) = self.tabs.iter().position(|tab| tab.id == self.active) else {
            return;
        };
        if url == "about:blank" {
            self.tabs[index].view = None;
            self.tabs[index].visible = false;
            self.tabs[index].generation += 1;
            self.tabs[index].loading = false;
            self.tabs[index].title = "New tab".into();
            self.tabs[index].site_color = None;
        } else if let Some(view) = &self.tabs[index].view {
            if let Err(error) = view.load_url(&url) {
                eprintln!("Cannot load {url}: {error}");
                return;
            }
            self.tabs[index].loading = true;
        } else {
            let generation = self.tabs[index].generation + 1;
            match self.build_view(self.active, generation, &url) {
                Ok(view) => {
                    self.tabs[index].view = Some(view);
                    self.tabs[index].generation = generation;
                    self.tabs[index].loading = true;
                }
                Err(error) => {
                    eprintln!("Cannot load {url}: {error}");
                    return;
                }
            }
        }
        self.tabs[index].favicon = crate::favicon::fallback(&url);
        self.tabs[index].url = url;
        self.tabs[index].last_used = Instant::now();
        self.panel = None;
        self.resize();
        self.reap_tabs();
    }

    pub(crate) fn reap_tabs(&mut self) {
        let now = Instant::now();
        let mut changed = false;
        for tab in &mut self.tabs {
            if tab.id != self.active
                && tab.view.is_some()
                && eviction_score(now.duration_since(tab.last_used), tab.activations)
                    >= IDLE_TAB_AGE.as_millis()
            {
                tab.view = None;
                tab.visible = false;
                tab.loading = false;
                tab.generation += 1;
                changed = true;
            }
        }
        while self.tabs.iter().filter(|tab| tab.view.is_some()).count() > MAX_LIVE_TABS {
            let candidate = self
                .tabs
                .iter()
                .enumerate()
                .filter(|(_, tab)| tab.id != self.active && tab.view.is_some())
                .max_by_key(|(_, tab)| {
                    (
                        eviction_score(now.duration_since(tab.last_used), tab.activations),
                        Reverse(tab.last_used),
                    )
                })
                .map(|(index, _)| index);
            let Some(index) = candidate else { break };
            self.tabs[index].view = None;
            self.tabs[index].visible = false;
            self.tabs[index].loading = false;
            self.tabs[index].generation += 1;
            changed = true;
        }
        if changed {
            self.refresh();
        }
    }

    fn close_tab(&mut self, id: u64) {
        let Some(index) = self.tabs.iter().position(|tab| tab.id == id) else {
            return;
        };
        let was_active = self.active == id;
        let tab = self.tabs.remove(index);
        if tab.url != "about:blank" {
            self.closed_tabs.push(tab.url);
            if self.closed_tabs.len() > 20 {
                self.closed_tabs.remove(0);
            }
        }
        if !self
            .tabs
            .iter()
            .any(|tab| tab.workspace == self.active_workspace)
        {
            if let Err(error) = self.new_tab("about:blank") {
                eprintln!("Cannot open tab: {error}");
            }
        } else if was_active {
            let next = self.tabs[index.min(self.tabs.len() - 1)..]
                .iter()
                .chain(self.tabs[..index.min(self.tabs.len())].iter())
                .find(|tab| tab.workspace == self.active_workspace)
                .map(|tab| tab.id);
            if let Some(id) = next {
                self.switch_tab(id);
            }
        } else {
            self.refresh();
        }
    }

    fn handle_command(&mut self, command: Command) {
        match command {
            Command::SetSidebarWidth { width } => {
                self.data.sidebar_width = width.clamp(180, 360);
                self.last_size = None;
                self.resize();
            }
            Command::Navigate { value } => {
                self.navigate_active(resolve_address(&value));
            }
            Command::NewTab => {
                #[cfg(target_os = "macos")]
                crate::native_chrome::focus_new_tab();
            }
            Command::OpenNewTab { value } => {
                if !value.trim().is_empty() {
                    let url = resolve_address(&value);
                    if let Err(error) = self.new_tab(&url) {
                        eprintln!("Cannot open tab: {error}");
                    }
                }
            }
            Command::OpenBlankTab => {
                if let Err(error) = self.new_tab("about:blank") {
                    eprintln!("Cannot open blank tab: {error}");
                }
            }
            Command::SetNewTabPhoto { path } => {
                if let Err(error) = self.set_new_tab_photo(&path) {
                    eprintln!("Cannot set new tab photo: {error}");
                }
            }
            Command::RemoveNewTabPhoto => {
                if let Err(error) = fs::remove_file(&self.photo_path) {
                    if error.kind() != std::io::ErrorKind::NotFound {
                        eprintln!("Cannot remove new tab photo: {error}");
                    }
                }
                self.photo_version += 1;
            }
            Command::SetPhotoPosition { x, y } => {
                self.data.photo_focus_x = x.min(100);
                self.data.photo_focus_y = y.min(100);
            }
            Command::ReopenClosedTab => {
                if let Some(url) = self.closed_tabs.pop() {
                    if let Err(error) = self.new_tab(&url) {
                        eprintln!("Cannot reopen tab: {error}");
                        self.closed_tabs.push(url);
                    }
                }
            }
            Command::SwitchTab { id } => self.switch_tab(id),
            Command::SwitchTabByIndex { index } => {
                let visible: Vec<_> = self
                    .tabs
                    .iter()
                    .filter(|tab| tab.workspace == self.active_workspace)
                    .collect();
                if let Some(id) = shortcut_tab_index(index, visible.len())
                    .and_then(|index| visible.get(index).map(|tab| tab.id))
                {
                    self.switch_tab(id);
                }
            }
            Command::NextTab | Command::PreviousTab => {
                let visible: Vec<_> = self
                    .tabs
                    .iter()
                    .filter(|tab| tab.workspace == self.active_workspace)
                    .collect();
                if let Some(index) = visible.iter().position(|tab| tab.id == self.active) {
                    if let Some(target) = adjacent_tab_index(
                        index,
                        visible.len(),
                        matches!(command, Command::NextTab),
                    ) {
                        self.switch_tab(visible[target].id);
                    }
                }
            }
            Command::CloseTab { id } => self.close_tab(id),
            Command::Back => {
                if let Some(tab) = self.active_tab() {
                    if let Some(view) = &tab.view {
                        let _ = view.go_back();
                    }
                }
            }
            Command::Forward => {
                if let Some(tab) = self.active_tab() {
                    if let Some(view) = &tab.view {
                        let _ = view.go_forward();
                    }
                }
            }
            Command::Reload => {
                if let Some(tab) = self.active_tab() {
                    if let Some(view) = &tab.view {
                        let _ = view.reload();
                    }
                }
            }
            Command::ToggleBookmark => {
                if let Some(tab) = self.active_tab() {
                    let (url, title) = (tab.url.clone(), tab.title.clone());
                    self.data.toggle_bookmark(&url, &title);
                    self.save();
                }
            }
            Command::ShowPanel { panel } => {
                self.panel = panel.filter(|value| {
                    matches!(
                        value.as_str(),
                        "bookmarks" | "history" | "downloads" | "tools"
                    )
                });
                self.resize();
            }
            Command::OpenSaved { url } => {
                self.navigate_active(resolve_address(&url));
            }
            Command::ClearHistory => {
                self.data.history.clear();
            }
            Command::NewWorkspace => {
                let id = self
                    .data
                    .workspaces
                    .iter()
                    .map(|space| space.id)
                    .max()
                    .unwrap_or(0)
                    + 1;
                let name = format!("Space {}", self.data.workspaces.len() + 1);
                self.data.workspaces.push(Workspace { id, name });
                self.active_workspace = id;
                if let Err(error) = self.new_tab("about:blank") {
                    eprintln!("Cannot open workspace: {error}");
                }
            }
            Command::SwitchWorkspace { id } => {
                if self.data.workspaces.iter().any(|space| space.id == id) {
                    if let Some(tab_id) = self
                        .tabs
                        .iter()
                        .find(|tab| tab.workspace == id)
                        .map(|tab| tab.id)
                    {
                        self.switch_tab(tab_id);
                    } else {
                        self.active_workspace = id;
                        if let Err(error) = self.new_tab("about:blank") {
                            eprintln!("Cannot open workspace tab: {error}");
                        }
                    }
                }
            }
            Command::RenameWorkspace { name } => {
                let name = name.trim();
                if !name.is_empty() && name.chars().count() <= 40 {
                    if let Some(space) = self
                        .data
                        .workspaces
                        .iter_mut()
                        .find(|space| space.id == self.active_workspace)
                    {
                        space.name = name.into();
                    }
                }
            }
            Command::MoveTab { id, workspace } => {
                if self
                    .data
                    .workspaces
                    .iter()
                    .any(|space| space.id == workspace)
                {
                    if let Some(tab) = self.tabs.iter_mut().find(|tab| tab.id == id) {
                        tab.workspace = workspace;
                    }
                    if self.active == id {
                        self.active_workspace = workspace;
                    }
                    self.resize();
                }
            }
        }
        self.save();
        self.refresh();
    }

    pub(crate) fn handle_event(&mut self, event: BrowserEvent) {
        match event {
            #[cfg(target_os = "macos")]
            BrowserEvent::Menu(event) => self.handle_menu(event),
            BrowserEvent::Command(command) => self.handle_command(command),
            BrowserEvent::PageStarted(id, generation, url) => {
                if let Some(tab) = self
                    .tabs
                    .iter_mut()
                    .find(|tab| tab.id == id && tab.generation == generation && tab.view.is_some())
                {
                    tab.favicon = crate::favicon::fallback(&url);
                    tab.url = url;
                    tab.loading = true;
                    tab.site_color = None;
                    self.save();
                } else {
                    return;
                }
                self.resize();
                self.refresh();
            }
            BrowserEvent::PageFinished(id, generation, url) => {
                if let Some(tab) = self
                    .tabs
                    .iter_mut()
                    .find(|tab| tab.id == id && tab.generation == generation && tab.view.is_some())
                {
                    tab.url = url.clone();
                    tab.loading = false;
                    self.data.visit(&url, &tab.title);
                    self.save();
                } else {
                    return;
                }
                self.sample_site_color(id, generation);
                self.reap_tabs();
                self.resize();
                self.request_favicon(id, generation);
                self.refresh();
            }
            BrowserEvent::SiteColor(id, generation, url, color) => {
                if let Some(tab) = self.tabs.iter_mut().find(|tab|
                    tab.id == id && tab.generation == generation && tab.view.is_some()
                        && !tab.loading && tab.url == url)
                {
                    tab.site_color = Some(color);
                    self.refresh();
                }
            }
            BrowserEvent::TitleChanged(id, generation, title) => {
                if let Some(tab) = self
                    .tabs
                    .iter_mut()
                    .find(|tab| tab.id == id && tab.generation == generation && tab.view.is_some())
                {
                    tab.title = if title.trim().is_empty() {
                        if tab.url == "about:blank" {
                            "New tab".into()
                        } else {
                            tab.url.clone()
                        }
                    } else {
                        title
                    };
                    if let Some(entry) = self
                        .data
                        .history
                        .iter_mut()
                        .find(|entry| entry.url == tab.url)
                    {
                        entry.title = tab.title.clone();
                        self.save();
                    }
                } else {
                    return;
                }
                self.sample_site_color(id, generation);
                self.request_favicon(id, generation);
                self.refresh();
            }
            BrowserEvent::FaviconChanged(id, generation, icon) => {
                if let Some(tab) = self.tabs.iter_mut().find(|tab| {
                    tab.id == id
                        && tab.generation == generation
                        // Read the live URL: sites like Gmail update the fragment
                        // without emitting a page-load event.
                        && tab.view.as_ref().and_then(|view| view.url().ok()).as_deref()
                            == Some(icon.page.as_str())
                }) {
                    let favicon = icon.icon.as_deref().and_then(crate::favicon::web_icon);
                    if tab.favicon != favicon {
                        tab.favicon = favicon;
                        self.refresh();
                    }
                }
            }
            BrowserEvent::OpenTab(url) => {
                if let Err(error) = self.new_tab(&url) {
                    eprintln!("Cannot open tab: {error}");
                }
                self.save();
            }
            BrowserEvent::DownloadStarted(url, path) => {
                self.downloads.insert(
                    0,
                    Download {
                        filename: std::path::Path::new(&path)
                            .file_name()
                            .and_then(|name| name.to_str())
                            .unwrap_or("download")
                            .to_owned(),
                        url,
                        complete: false,
                        success: false,
                    },
                );
                self.downloads.truncate(50);
                self.refresh();
            }
            BrowserEvent::DownloadFinished(url, success) => {
                if let Some(download) = self
                    .downloads
                    .iter_mut()
                    .find(|download| download.url == url && !download.complete)
                {
                    download.complete = true;
                    download.success = success;
                }
                self.refresh();
            }
        }
    }

    fn request_favicon(&self, id: u64, generation: u64) {
        let Some(view) = self
            .tabs
            .iter()
            .find(|tab| tab.id == id && tab.generation == generation)
            .and_then(|tab| tab.view.as_ref())
        else {
            return;
        };
        let proxy = self.proxy.clone();
        let _ = view.evaluate_script_with_callback(crate::favicon::SCRIPT, move |result| {
            if let Ok(icon) = serde_json::from_str::<crate::favicon::PageIcon>(&result) {
                let _ = proxy.send_event(BrowserEvent::FaviconChanged(id, generation, icon));
            }
        });
    }

    #[cfg(target_os = "macos")]
    fn handle_menu(&mut self, event: MenuEvent) {
        match event.id.0.as_str() {
            "address" => {
                crate::native_chrome::focus_address();
            }
            "switcher" => crate::native_chrome::focus_switcher(),
            "new_tab" => self.handle_command(Command::NewTab),
            "reopen_tab" => self.handle_command(Command::ReopenClosedTab),
            "close_tab" => self.handle_command(Command::CloseTab { id: self.active }),
            "next_tab" => self.handle_command(Command::NextTab),
            "previous_tab" => self.handle_command(Command::PreviousTab),
            id if id.starts_with("tab_") => {
                if let Some(index) = id[4..]
                    .parse::<usize>()
                    .ok()
                    .and_then(|number| number.checked_sub(1))
                {
                    self.handle_command(Command::SwitchTabByIndex { index });
                }
            }
            "back" => self.handle_command(Command::Back),
            "forward" => self.handle_command(Command::Forward),
            "reload" => self.handle_command(Command::Reload),
            "bookmark" => self.handle_command(Command::ToggleBookmark),
            "history" => self.handle_command(Command::ShowPanel {
                panel: Some("history".into()),
            }),
            "bookmarks" => self.handle_command(Command::ShowPanel {
                panel: Some("bookmarks".into()),
            }),
            "downloads" => self.handle_command(Command::ShowPanel {
                panel: Some("downloads".into()),
            }),
            _ => {}
        }
    }

    fn save(&mut self) {
        if self.save_due.is_none() {
            self.save_due = Some(Instant::now() + Duration::from_millis(500));
        }
    }

    pub(crate) fn save_deadline(&self) -> Option<Instant> {
        self.save_due
    }

    pub(crate) fn flush_save_if_due(&mut self) {
        if self.save_due.is_some_and(|due| Instant::now() >= due) {
            self.flush_save();
        }
    }

    pub(crate) fn flush_save(&mut self) {
        if self.save_due.take().is_none() {
            return;
        }
        self.data.active_workspace = self.active_workspace;
        self.data.session_tabs = self
            .tabs
            .iter()
            .map(|tab| SessionTab {
                url: tab.url.clone(),
                workspace: tab.workspace,
            })
            .collect();
        self.data.active_tab_index = self
            .tabs
            .iter()
            .position(|tab| tab.id == self.active)
            .unwrap_or(0);
        if let Err(error) = self.data.save(&self.data_path) {
            eprintln!("Cannot save browser data: {error}");
        }
    }

    fn set_new_tab_photo(&mut self, source: &str) -> std::io::Result<()> {
        let source = PathBuf::from(source);
        let metadata = fs::metadata(&source)?;
        if !metadata.is_file() || metadata.len() > 30 * 1024 * 1024 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Photo must be a file under 30 MB",
            ));
        }
        let bytes = fs::read(&source)?;
        if photo_mime(&bytes).is_none() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Unsupported photo format",
            ));
        }
        if let Some(parent) = self.photo_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = self.photo_path.with_extension("tmp");
        fs::write(&temporary, bytes)?;
        fs::rename(temporary, &self.photo_path)?;
        self.data.photo_focus_x = 50;
        self.data.photo_focus_y = 50;
        self.photo_version += 1;
        Ok(())
    }

    fn refresh(&self) {
        let active = self.active_tab();
        let state = ShellState {
            tabs: self
                .tabs
                .iter()
                .map(|tab| TabState {
                    id: tab.id,
                    workspace: tab.workspace,
                    url: &tab.url,
                    title: &tab.title,
                    favicon: tab.favicon.as_deref(),
                    loading: tab.loading,
                    sleeping: tab.view.is_none() && tab.url != "about:blank",
                })
                .collect(),
            workspaces: &self.data.workspaces,
            active: self.active,
            active_workspace: self.active_workspace,
            bookmarks: if self.panel.as_deref() == Some("bookmarks") {
                &self.data.bookmarks
            } else {
                &[]
            },
            history: if self.panel.as_deref() == Some("history") {
                &self.data.history
            } else {
                &[]
            },
            downloads: if self.panel.as_deref() == Some("downloads") {
                &self.downloads
            } else {
                &[]
            },
            panel: self.panel.as_deref(),
            bookmarked: active
                .is_some_and(|tab| self.data.bookmarks.iter().any(|entry| entry.url == tab.url)),
            can_go_back: active
                .and_then(|tab| tab.view.as_ref())
                .is_some_and(|view| view.can_go_back().unwrap_or(false)),
            can_go_forward: active
                .and_then(|tab| tab.view.as_ref())
                .is_some_and(|view| view.can_go_forward().unwrap_or(false)),
            has_photo: self.photo_path.exists(),
            photo_version: self.photo_version,
            photo_focus_x: self.data.photo_focus_x,
            photo_focus_y: self.data.photo_focus_y,
            sidebar_width: self.data.sidebar_width,
            site_color: active.and_then(|tab| tab.site_color),
        };
        if let Ok(json) = serde_json::to_string(&state) {
            #[cfg(target_os = "macos")]
            crate::native_chrome::update(&json);
            let _ = self
                .shell
                .evaluate_script(&format!("window.renderState({json})"));
        }
        if let Some(tab) = active {
            self.window.set_title(&format!("{} — Moth", tab.title));
        }
    }
}

fn rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
    Rect {
        position: LogicalPosition::new(x, y).into(),
        size: LogicalSize::new(width.max(1.0), height.max(1.0)).into(),
    }
}

fn photo_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some("image/gif")
    } else if bytes.len() >= 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else if bytes.len() >= 12
        && &bytes[4..8] == b"ftyp"
        && matches!(&bytes[8..12], b"heic" | b"heix" | b"mif1" | b"hevc")
    {
        Some("image/heic")
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::{
        adjacent_tab_index, eviction_score, photo_mime, record_tab_switch, shortcut_tab_index, Tab,
        IDLE_TAB_AGE,
    };
    use std::time::{Duration, Instant};

    fn tab(id: u64, last_used: Instant) -> Tab {
        Tab {
            id,
            workspace: 1,
            view: None,
            visible: false,
            generation: 0,
            last_used,
            activations: 1,
            url: "about:blank".into(),
            title: "New tab".into(),
            favicon: None,
            loading: false,
            site_color: None,
        }
    }

    #[test]
    fn leaving_a_long_read_starts_a_fresh_idle_period() {
        let opened = Instant::now();
        let switched = opened + Duration::from_secs(7200);
        let mut tabs = vec![tab(1, opened), tab(2, opened), tab(3, opened)];
        record_tab_switch(&mut tabs, 1, 2, switched);
        assert_eq!(tabs[0].last_used, switched);
        assert_eq!(tabs[1].last_used, switched);
        assert_eq!(tabs[2].last_used, opened);
        assert_eq!(tabs[0].activations, 1);
        assert_eq!(tabs[1].activations, 2);
        assert!(
            eviction_score(switched - tabs[0].last_used, tabs[0].activations)
                < IDLE_TAB_AGE.as_millis()
        );
    }

    #[test]
    fn reselecting_active_tab_does_not_inflate_frequency() {
        let now = Instant::now();
        let mut tabs = vec![tab(1, now), tab(2, now)];
        record_tab_switch(&mut tabs, 1, 1, now + Duration::from_secs(60));
        assert_eq!(tabs[0].activations, 1);
        assert_eq!(tabs[1].activations, 1);
    }

    #[test]
    fn frequently_used_tabs_get_more_time_before_eviction() {
        assert_eq!(eviction_score(Duration::from_secs(900), 1), 900_000);
        assert_eq!(eviction_score(Duration::from_secs(900), 4), 225_000);
        assert_eq!(eviction_score(Duration::from_secs(3600), 4), 900_000);
        assert!(
            eviction_score(Duration::from_millis(120), 1)
                > eviction_score(Duration::from_millis(80), 1)
        );
    }

    #[test]
    fn numbered_tabs_follow_browser_conventions() {
        assert_eq!(shortcut_tab_index(0, 3), Some(0));
        assert_eq!(shortcut_tab_index(2, 3), Some(2));
        assert_eq!(shortcut_tab_index(3, 3), None);
        assert_eq!(shortcut_tab_index(8, 3), Some(2));
        assert_eq!(shortcut_tab_index(8, 0), None);
    }

    #[test]
    fn adjacent_tabs_wrap_around() {
        assert_eq!(adjacent_tab_index(2, 3, true), Some(0));
        assert_eq!(adjacent_tab_index(0, 3, false), Some(2));
        assert_eq!(adjacent_tab_index(0, 1, true), Some(0));
        assert_eq!(adjacent_tab_index(0, 0, true), None);
    }

    #[test]
    fn photo_format_comes_from_file_content() {
        assert_eq!(photo_mime(b"\x89PNG\r\n\x1a\nimage"), Some("image/png"));
        assert_eq!(photo_mime(b"\xff\xd8\xffimage"), Some("image/jpeg"));
        assert_eq!(photo_mime(b"not an image"), None);
    }
}
