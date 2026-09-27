use std::{
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

static DOWNLOAD_ID: AtomicU64 = AtomicU64::new(1);

pub(crate) fn unique_download_path(directory: &Path, filename: &str) -> PathBuf {
    let sanitized = Path::new(filename)
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|name| !name.is_empty())
        .unwrap_or("download");
    let candidate = directory.join(sanitized);
    if !candidate.exists() {
        return candidate;
    }
    let stem = Path::new(sanitized)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("download");
    let extension = Path::new(sanitized).extension().and_then(|s| s.to_str());
    loop {
        let id = DOWNLOAD_ID.fetch_add(1, Ordering::Relaxed);
        let name = match extension {
            Some(ext) => format!("{stem} ({id}).{ext}"),
            None => format!("{stem} ({id})"),
        };
        let candidate = directory.join(name);
        if !candidate.exists() {
            return candidate;
        }
    }
}
