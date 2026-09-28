mod address;
mod app;
mod browser;
mod data;
mod downloads;
mod favicon;
#[cfg(target_os = "macos")]
mod native_chrome;
mod protocol;

fn main() {
    app::run();
}
