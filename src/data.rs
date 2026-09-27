use serde::{Deserialize, Serialize};
use std::{
    fs, io,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Serialize, Deserialize)]
pub struct Entry {
    pub url: String,
    pub title: String,
    pub visited_at: u64,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Workspace {
    pub id: u64,
    pub name: String,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct SessionTab {
    pub url: String,
    pub workspace: u64,
}

#[derive(Serialize, Deserialize)]
pub struct BrowserData {
    pub bookmarks: Vec<Entry>,
    pub history: Vec<Entry>,
    #[serde(default = "default_workspaces")]
    pub workspaces: Vec<Workspace>,
    #[serde(default = "default_workspace_id")]
    pub active_workspace: u64,
    #[serde(default)]
    pub session_tabs: Vec<SessionTab>,
    #[serde(default)]
    pub active_tab_index: usize,
    #[serde(default = "default_photo_focus")]
    pub photo_focus_x: u8,
    #[serde(default = "default_photo_focus")]
    pub photo_focus_y: u8,
}

fn default_photo_focus() -> u8 {
    50
}

fn default_workspace_id() -> u64 {
    1
}

fn default_workspaces() -> Vec<Workspace> {
    vec![Workspace {
        id: 1,
        name: "Personal".into(),
    }]
}

impl Default for BrowserData {
    fn default() -> Self {
        Self {
            bookmarks: Vec::new(),
            history: Vec::new(),
            workspaces: default_workspaces(),
            active_workspace: 1,
            session_tabs: Vec::new(),
            active_tab_index: 0,
            photo_focus_x: default_photo_focus(),
            photo_focus_y: default_photo_focus(),
        }
    }
}

impl BrowserData {
    pub fn load(path: &Path) -> Self {
        let mut data: Self = fs::read(path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        if data.workspaces.is_empty() {
            data.workspaces = default_workspaces();
        }
        if !data
            .workspaces
            .iter()
            .any(|space| space.id == data.active_workspace)
        {
            data.active_workspace = data.workspaces[0].id;
        }
        data.photo_focus_x = data.photo_focus_x.min(100);
        data.photo_focus_y = data.photo_focus_y.min(100);
        data
    }

    pub fn save(&self, path: &Path) -> io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temp = path.with_extension("json.tmp");
        fs::write(&temp, serde_json::to_vec_pretty(self)?)?;
        fs::rename(temp, path)
    }

    pub fn visit(&mut self, url: &str, title: &str) {
        if !is_recordable(url) {
            return;
        }
        if self.history.first().is_some_and(|entry| entry.url == url) {
            self.history.remove(0);
        }
        self.history.insert(0, Entry::new(url, title));
        self.history.truncate(500);
    }

    pub fn toggle_bookmark(&mut self, url: &str, title: &str) {
        if let Some(index) = self.bookmarks.iter().position(|entry| entry.url == url) {
            self.bookmarks.remove(index);
        } else if is_recordable(url) {
            self.bookmarks.insert(0, Entry::new(url, title));
        }
    }
}

impl Entry {
    fn new(url: &str, title: &str) -> Self {
        Self {
            url: url.to_owned(),
            title: if title.trim().is_empty() { url } else { title }.to_owned(),
            visited_at: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
        }
    }
}

fn is_recordable(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://") || url.starts_with("file://")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bookmarks_toggle_and_history_is_bounded() {
        let mut data = BrowserData::default();
        data.toggle_bookmark("https://example.com", "Example");
        assert_eq!(data.bookmarks.len(), 1);
        data.toggle_bookmark("https://example.com", "Example");
        assert!(data.bookmarks.is_empty());
        for n in 0..510 {
            data.visit(&format!("https://example.com/{n}"), "Example");
        }
        assert_eq!(data.history.len(), 500);
    }

    #[test]
    fn older_state_defaults_to_centered_photo() {
        let state: BrowserData = serde_json::from_str("{\"bookmarks\":[],\"history\":[]}").unwrap();
        assert_eq!((state.photo_focus_x, state.photo_focus_y), (50, 50));
        assert_eq!(state.active_tab_index, 0);
    }
}
