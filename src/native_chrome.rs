use crate::protocol::{BrowserEvent, Command};
use std::{
    ffi::{c_char, c_void, CStr, CString},
    path::Path,
    sync::OnceLock,
};
use tao::event_loop::EventLoopProxy;
use wry::raw_window_handle::{HasWindowHandle, RawWindowHandle};

static PROXY: OnceLock<EventLoopProxy<BrowserEvent>> = OnceLock::new();

unsafe extern "C" {
    fn moth_install_chrome(
        parent: *mut c_void,
        callback: extern "C" fn(*const c_char),
        photo_path: *const c_char,
    );
    fn moth_resize_chrome(width: f64, height: f64);
    fn moth_update_chrome(json: *const c_char);
    fn moth_focus_address();
    fn moth_focus_switcher();
    fn moth_focus_new_tab();
}

extern "C" fn receive_command(json: *const c_char) {
    if json.is_null() {
        return;
    }
    let Ok(text) = (unsafe { CStr::from_ptr(json) }).to_str() else {
        return;
    };
    if let Ok(command) = serde_json::from_str::<Command>(text) {
        if let Some(proxy) = PROXY.get() {
            let _ = proxy.send_event(BrowserEvent::Command(command));
        }
    }
}

pub(crate) fn install(
    window: &tao::window::Window,
    proxy: EventLoopProxy<BrowserEvent>,
    photo_path: &Path,
) {
    let _ = PROXY.set(proxy);
    let Ok(handle) = window.window_handle() else {
        return;
    };
    if let (RawWindowHandle::AppKit(handle), Ok(path)) = (
        handle.as_raw(),
        CString::new(photo_path.to_string_lossy().as_bytes()),
    ) {
        unsafe {
            moth_install_chrome(handle.ns_view.as_ptr(), receive_command, path.as_ptr());
        }
    }
}

pub(crate) fn resize(width: f64, height: f64) {
    unsafe {
        moth_resize_chrome(width, height);
    }
}

pub(crate) fn update(json: &str) {
    if let Ok(json) = CString::new(json) {
        unsafe {
            moth_update_chrome(json.as_ptr());
        }
    }
}

pub(crate) fn focus_address() {
    unsafe {
        moth_focus_address();
    }
}
pub(crate) fn focus_switcher() {
    unsafe {
        moth_focus_switcher();
    }
}

pub(crate) fn focus_new_tab() {
    unsafe {
        moth_focus_new_tab();
    }
}
