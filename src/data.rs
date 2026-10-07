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
    #[serde(default)]
    pub project: Project,
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Project {
    pub local: String,
    pub repository: String,
    pub docs: String,
    pub staging: String,
    pub production: String,
    pub split: bool,
}
impl Project {
    pub fn valid(&self) -> bool {
        [
            &self.local,
            &self.repository,
            &self.docs,
            &self.staging,
            &self.production,
        ]
        .iter()
        .all(|value| {
            value.is_empty()
                || (value.len() <= 4096
                    && url::Url::parse(value).is_ok_and(|u| {
                        matches!(u.scheme(), "http" | "https")
                            && u.host_str().is_some()
                            && u.username().is_empty()
                            && u.password().is_none()
                    }))
        })
    }
}

#[derive(Clone, Serialize, Deserialize)]
pub struct SessionTab {
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub keep_awake: bool,
    pub url: String,
    pub workspace: u64,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct BrowserData {
    #[serde(default)]
    pub settings: Settings,
    #[serde(default)]
    pub downloads: Vec<Download>,
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
    #[serde(default = "default_sidebar_width")]
    pub sidebar_width: u16,
}

fn default_sidebar_width() -> u16 {
    220
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
        project: Project::default(),
    }]
}

impl Default for BrowserData {
    fn default() -> Self {
        Self {
            settings: Settings::default(),
            downloads: Vec::new(),
            bookmarks: Vec::new(),
            history: Vec::new(),
            workspaces: default_workspaces(),
            active_workspace: 1,
            session_tabs: Vec::new(),
            active_tab_index: 0,
            photo_focus_x: default_photo_focus(),
            photo_focus_y: default_photo_focus(),
            sidebar_width: default_sidebar_width(),
        }
    }
}

impl BrowserData {
    pub fn load(path: &Path) -> Self {
        let read = |p: &Path| {
            fs::read(p)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Self>(&bytes).ok())
        };
        let mut data = read(path)
            .or_else(|| read(&path.with_extension("json.bak")))
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
        data.sidebar_width = data.sidebar_width.clamp(180, 360);
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
        // Never replace the last good backup with corrupt input.
        if let Ok(bytes) = fs::read(path) {
            if serde_json::from_slice::<Self>(&bytes).is_ok() {
                fs::write(path.with_extension("json.bak"), bytes)?;
            } else {
                fs::write(path.with_extension("json.corrupt"), bytes)?;
            }
        }
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
    fn corrupt_state_recovers_backup_without_destroying_it() {
        let directory = std::env::temp_dir().join(format!(
            "moth-recovery-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let path = directory.join("state.json");
        let mut data = BrowserData::default();
        data.toggle_bookmark("https://example.com", "Kept");
        data.save(&path).unwrap();
        data.settings.search_engine = "bing".into();
        data.save(&path).unwrap();
        fs::write(&path, b"interrupted write").unwrap();
        let recovered = BrowserData::load(&path);
        assert_eq!(recovered.bookmarks[0].title, "Kept");
        assert_eq!(recovered.settings.search_engine, "google");
        recovered.save(&path).unwrap();
        assert_eq!(
            fs::read(path.with_extension("json.corrupt")).unwrap(),
            b"interrupted write"
        );
        assert_eq!(BrowserData::load(&path).bookmarks.len(), 1);
        let backup: BrowserData =
            serde_json::from_slice(&fs::read(path.with_extension("json.bak")).unwrap()).unwrap();
        assert_eq!(backup.bookmarks.len(), 1);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn legacy_sessions_default_to_unpinned_and_safe_settings() {
        let data: BrowserData = serde_json::from_str(r#"{"bookmarks":[],"history":[],"session_tabs":[{"url":"https://example.com","workspace":1}]}"#).unwrap();
        assert!(!data.session_tabs[0].pinned);
        assert!(!data.session_tabs[0].keep_awake);
        assert!(data.workspaces[0].project.local.is_empty());
        assert!(data.settings.site_permissions.is_empty());
        assert!(data.settings.restore_session);
        assert!(data.downloads.is_empty());
    }

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
    fn sidebar_width_survives_serialization() {
        let state = BrowserData {
            sidebar_width: 310,
            ..BrowserData::default()
        };
        let restored: BrowserData =
            serde_json::from_str(&serde_json::to_string(&state).unwrap()).unwrap();
        assert_eq!(restored.sidebar_width, 310);
    }

    #[test]
    fn older_state_defaults_to_centered_photo() {
        let state: BrowserData = serde_json::from_str("{\"bookmarks\":[],\"history\":[]}").unwrap();
        assert_eq!((state.photo_focus_x, state.photo_focus_y), (50, 50));
        assert_eq!(state.active_tab_index, 0);
        assert_eq!(state.sidebar_width, 220);
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub search_engine: String,
    pub download_directory: String,
    pub restore_session: bool,
    pub appearance: String,
    pub site_permissions: std::collections::BTreeMap<String, String>,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            search_engine: "google".into(),
            download_directory: String::new(),
            restore_session: true,
            appearance: "system".into(),
            site_permissions: Default::default(),
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Download {
    pub id: String,
    pub url: String,
    pub filename: String,
    pub path: String,
    pub complete: bool,
    pub success: bool,
    pub progress: f64,
}
