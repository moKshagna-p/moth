#[cfg(target_os = "macos")]
use muda::MenuEvent;
use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(crate) enum Command {
    Navigate { value: String },
    NewTab,
    OpenNewTab { value: String },
    OpenBlankTab,
    SetNewTabPhoto { path: String },
    SetPhotoPosition { x: u8, y: u8 },
    RemoveNewTabPhoto,
    ReopenClosedTab,
    SwitchTab { id: u64 },
    SwitchTabByIndex { index: usize },
    NextTab,
    PreviousTab,
    CloseTab { id: u64 },
    Back,
    Forward,
    Reload,
    ToggleBookmark,
    ShowPanel { panel: Option<String> },
    OpenSaved { url: String },
    ClearHistory,
    NewWorkspace,
    SwitchWorkspace { id: u64 },
    RenameWorkspace { name: String },
    MoveTab { id: u64, workspace: u64 },
}

pub(crate) enum BrowserEvent {
    #[cfg(target_os = "macos")]
    Menu(MenuEvent),
    Command(Command),
    PageStarted(u64, String),
    PageFinished(u64, String),
    TitleChanged(u64, String),
    OpenTab(String),
    DownloadStarted(String, String),
    DownloadFinished(String, bool),
}
