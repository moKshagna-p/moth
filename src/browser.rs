use crate::{
    address::resolve_address,
    data::{BrowserData, Entry, SessionTab, Workspace},
    downloads::unique_download_path,
    protocol::{BrowserEvent, Command},
};
#[cfg(target_os = "macos")]
use muda::MenuEvent;
use serde::Serialize;
use std::{borrow::Cow, fs, path::PathBuf};
use tao::{
    dpi::{LogicalPosition, LogicalSize},
    event_loop::EventLoopProxy,
    window::Window,
};
use wry::{http::Response, NewWindowResponse, PageLoadEvent, Rect, WebView, WebViewBuilder};

const SIDEBAR_WIDTH: f64 = 252.0;
const TOOLBAR_HEIGHT: f64 = 68.0;

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

struct Tab {
    id: u64,
    workspace: u64,
    view: WebView,
    url: String,
    title: String,
    loading: bool,
}

#[derive(Serialize)]
struct TabState<'a> {
    id: u64,
    workspace: u64,
    url: &'a str,
    title: &'a str,
    loading: bool,
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
            proxy,
        };
        browser.resize();
        for tab in restored_tabs {
            if browser
                .data
                .workspaces
                .iter()
                .any(|space| space.id == tab.workspace)
            {
                browser.new_tab_in_workspace(&tab.url, tab.workspace)?;
            }
        }
        if let Some(id) = browser
            .tabs
            .iter()
            .find(|tab| tab.workspace == active_workspace)
            .map(|tab| tab.id)
        {
            browser.active = id;
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

    pub(crate) fn resize(&self) {
        let size = self.size();
        let show_shell_page = self.panel.is_some()
            || self
                .active_tab()
                .is_some_and(|tab| tab.url == "about:blank");
        let content_width = (size.width - SIDEBAR_WIDTH).max(1.0);
        let content_height = (size.height - TOOLBAR_HEIGHT).max(1.0);
        let _ = self.shell.set_bounds(rect(
            SIDEBAR_WIDTH,
            TOOLBAR_HEIGHT,
            content_width,
            content_height,
        ));
        let _ = self.shell.set_visible(show_shell_page);
        #[cfg(target_os = "macos")]
        crate::native_chrome::resize(size.width, size.height);
        for tab in &self.tabs {
            let _ = tab.view.set_bounds(rect(
                SIDEBAR_WIDTH,
                TOOLBAR_HEIGHT,
                content_width,
                content_height,
            ));
            let _ = tab
                .view
                .set_visible(tab.id == self.active && !show_shell_page);
        }
    }

    fn new_tab(&mut self, url: &str) -> wry::Result<()> {
        self.new_tab_in_workspace(url, self.active_workspace)
    }

    fn new_tab_in_workspace(&mut self, url: &str, workspace: u64) -> wry::Result<()> {
        let id = self.next_tab_id;
        self.next_tab_id += 1;
        let size = self.size();
        let load_proxy = self.proxy.clone();
        let title_proxy = self.proxy.clone();
        let window_proxy = self.proxy.clone();
        let download_proxy = self.proxy.clone();
        let completed_proxy = self.proxy.clone();
        let view = WebViewBuilder::new()
            .with_url(url)
            .with_bounds(rect(
                SIDEBAR_WIDTH,
                TOOLBAR_HEIGHT,
                (size.width - SIDEBAR_WIDTH).max(1.0),
                (size.height - TOOLBAR_HEIGHT).max(1.0),
            ))
            .with_on_page_load_handler(move |event, url| {
                let message = match event {
                    PageLoadEvent::Started => BrowserEvent::PageStarted(id, url),
                    PageLoadEvent::Finished => BrowserEvent::PageFinished(id, url),
                };
                let _ = load_proxy.send_event(message);
            })
            .with_document_title_changed_handler(move |title| {
                let _ = title_proxy.send_event(BrowserEvent::TitleChanged(id, title));
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
            .build_as_child(&self.window)?;
        self.active = id;
        self.tabs.push(Tab {
            id,
            workspace,
            view,
            url: url.into(),
            title: "New tab".into(),
            loading: true,
        });
        self.panel = None;
        self.resize();
        self.refresh();
        Ok(())
    }

    fn active_tab(&self) -> Option<&Tab> {
        self.tabs.iter().find(|tab| tab.id == self.active)
    }

    fn active_tab_mut(&mut self) -> Option<&mut Tab> {
        self.tabs.iter_mut().find(|tab| tab.id == self.active)
    }

    fn switch_tab(&mut self, id: u64) {
        if !self.tabs.iter().any(|tab| tab.id == id) {
            return;
        }
        self.active = id;
        self.active_workspace = self
            .tabs
            .iter()
            .find(|tab| tab.id == id)
            .map(|tab| tab.workspace)
            .unwrap_or(self.active_workspace);
        self.panel = None;
        self.resize();
        self.refresh();
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
            Command::Navigate { value } => {
                let url = resolve_address(&value);
                if let Some(tab) = self.active_tab_mut() {
                    if let Err(error) = tab.view.load_url(&url) {
                        eprintln!("Cannot load {url}: {error}");
                    }
                    tab.url = url;
                    tab.loading = true;
                }
                self.panel = None;
                self.resize();
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
                    let _ = tab.view.go_back();
                }
            }
            Command::Forward => {
                if let Some(tab) = self.active_tab() {
                    let _ = tab.view.go_forward();
                }
            }
            Command::Reload => {
                if let Some(tab) = self.active_tab() {
                    let _ = tab.view.reload();
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
                let url = resolve_address(&url);
                if let Some(tab) = self.active_tab_mut() {
                    let _ = tab.view.load_url(&url);
                    tab.url = url;
                    tab.loading = true;
                }
                self.panel = None;
                self.resize();
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
                    self.active_workspace = id;
                    if let Some(tab) = self.tabs.iter().find(|tab| tab.workspace == id) {
                        self.active = tab.id;
                        self.panel = None;
                        self.resize();
                    } else if let Err(error) = self.new_tab("about:blank") {
                        eprintln!("Cannot open workspace tab: {error}");
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
            BrowserEvent::PageStarted(id, url) => {
                if let Some(tab) = self.tabs.iter_mut().find(|tab| tab.id == id) {
                    tab.url = url;
                    tab.loading = true;
                }
                self.resize();
                self.refresh();
            }
            BrowserEvent::PageFinished(id, url) => {
                if let Some(tab) = self.tabs.iter_mut().find(|tab| tab.id == id) {
                    tab.url = url.clone();
                    tab.loading = false;
                    self.data.visit(&url, &tab.title);
                    self.save();
                }
                self.resize();
                self.refresh();
            }
            BrowserEvent::TitleChanged(id, title) => {
                if let Some(tab) = self.tabs.iter_mut().find(|tab| tab.id == id) {
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
                }
                self.refresh();
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
        self.data.active_workspace = self.active_workspace;
        self.data.session_tabs = self
            .tabs
            .iter()
            .map(|tab| SessionTab {
                url: tab.url.clone(),
                workspace: tab.workspace,
            })
            .collect();
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
                    loading: tab.loading,
                })
                .collect(),
            workspaces: &self.data.workspaces,
            active: self.active,
            active_workspace: self.active_workspace,
            bookmarks: &self.data.bookmarks,
            history: &self.data.history,
            downloads: &self.downloads,
            panel: self.panel.as_deref(),
            bookmarked: active
                .is_some_and(|tab| self.data.bookmarks.iter().any(|entry| entry.url == tab.url)),
            can_go_back: active.is_some_and(|tab| tab.view.can_go_back().unwrap_or(false)),
            can_go_forward: active.is_some_and(|tab| tab.view.can_go_forward().unwrap_or(false)),
            has_photo: self.photo_path.exists(),
            photo_version: self.photo_version,
            photo_focus_x: self.data.photo_focus_x,
            photo_focus_y: self.data.photo_focus_y,
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
    use super::{adjacent_tab_index, photo_mime, shortcut_tab_index};

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
