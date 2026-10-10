#[cfg(target_os = "macos")]
use muda::MenuEvent;
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum Command {
    Navigate {
        value: String,
    },
    NewWindow {
        private: bool,
    },
    Find,
    Inspect,
    Screenshot,
    PictureInPicture,
    ProjectSettings,
    LocalProjects,
    SetProject {
        workspace: u64,
        project: crate::data::Project,
    },
    OpenProject,
    SwitchEnvironment {
        environment: String,
    },
    ClearCurrentSiteData,
    SetSplitRatio {
        ratio: f64,
    },
    SwapPanes,
    SetViewport {
        width: u16,
        height: u16,
    },
    ToggleKeepAwake {
        id: u64,
    },
    ToggleMedia {
        id: u64,
    },
    MediaState {
        id: u64,
        generation: u64,
        playing: bool,
        #[serde(default)]
        picture_in_picture: bool,
    },
    DismissPageError {
        id: u64,
    },
    Zoom {
        delta: i8,
    },
    Print,
    Settings,
    SetSettings {
        settings: crate::data::Settings,
    },
    ClearSiteData,
    DefaultBrowser,
    DuplicateTab {
        id: u64,
    },
    RenameTab {
        id: u64,
        title: String,
    },
    TogglePin {
        id: u64,
    },
    ReorderTab {
        id: u64,
        before: u64,
    },
    CloseOtherTabs {
        id: u64,
    },
    SplitTab {
        id: u64,
    },
    CloseSplit,
    FocusPane {
        id: u64,
    },
    PageError {
        id: u64,
        generation: u64,
        message: String,
    },
    DismissError,
    DownloadUpdate {
        download: crate::data::Download,
    },
    DownloadAction {
        id: String,
        action: String,
    },
    NewTab,
    OpenNewTab {
        value: String,
    },
    OpenBlankTab,
    SetNewTabPhoto {
        path: String,
    },
    SetSidebarWidth {
        width: u16,
    },
    SetPhotoPosition {
        x: u8,
        y: u8,
    },
    RemoveNewTabPhoto,
    ReopenClosedTab,
    SwitchTab {
        id: u64,
    },
    SwitchTabByIndex {
        index: usize,
    },
    NextTab,
    PreviousTab,
    CloseTab {
        id: u64,
    },
    Back,
    Forward,
    Reload,
    ToggleBookmark,
    ShowPanel {
        panel: Option<String>,
    },
    OpenSaved {
        url: String,
    },
    ClearHistory,
    NewWorkspace,
    SwitchWorkspace {
        id: u64,
    },
    RenameWorkspace {
        name: String,
    },
    MoveTab {
        id: u64,
        workspace: u64,
    },
}

pub(crate) enum BrowserEvent {
    Routed(u64, Box<BrowserEvent>),
    #[cfg(target_os = "macos")]
    Menu(MenuEvent),
    Command(Command),
    PageStarted(u64, u64, String),
    PageFinished(u64, u64, String),
    TitleChanged(u64, u64, String),
    SiteColor(u64, u64, String, [u8; 3]),
    FaviconChanged(u64, u64, crate::favicon::PageIcon),
    OpenTab(String),
    DownloadStarted(String, String),
    DownloadFinished(String, bool),
}

#[derive(Clone)]
pub(crate) struct BrowserProxy {
    pub id: u64,
    pub proxy: tao::event_loop::EventLoopProxy<BrowserEvent>,
}
impl BrowserProxy {
    pub fn send_event(
        &self,
        event: BrowserEvent,
    ) -> Result<(), Box<tao::event_loop::EventLoopClosed<BrowserEvent>>> {
        self.proxy
            .send_event(BrowserEvent::Routed(self.id, Box::new(event)))
            .map_err(Box::new)
    }
}
