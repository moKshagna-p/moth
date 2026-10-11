use crate::protocol::{BrowserEvent, BrowserProxy, Command};
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
        id: u64,
        parent: *mut c_void,
        callback: extern "C" fn(*const c_char),
        photo_path: *const c_char,
    );
    fn moth_resize_chrome(id: u64, width: f64, height: f64);
    fn moth_update_chrome(id: u64, json: *const c_char);
    fn moth_focus_address(id: u64);
    fn moth_focus_switcher(id: u64);
    fn moth_focus_new_tab(id: u64);
}

extern "C" fn receive_command(json: *const c_char) {
    if json.is_null() {
        return;
    }
    let Ok(text) = (unsafe { CStr::from_ptr(json) }).to_str() else {
        return;
    };
    let id = serde_json::from_str::<serde_json::Value>(text)
        .ok()
        .and_then(|v| v["window_id"].as_u64())
        .unwrap_or(0);
    if let Ok(command) = serde_json::from_str::<Command>(text) {
        if let Some(proxy) = PROXY.get() {
            let _ = proxy.send_event(BrowserEvent::Routed(
                id,
                Box::new(BrowserEvent::Command(command)),
            ));
        }
    }
}

pub(crate) fn install(window: &tao::window::Window, proxy: BrowserProxy, photo_path: &Path) {
    let id = proxy.id;
    let _ = PROXY.set(proxy.proxy);
    let Ok(handle) = window.window_handle() else {
        return;
    };
    if let (RawWindowHandle::AppKit(handle), Ok(path)) = (
        handle.as_raw(),
        CString::new(photo_path.to_string_lossy().as_bytes()),
    ) {
        unsafe {
            moth_install_chrome(id, handle.ns_view.as_ptr(), receive_command, path.as_ptr());
        }
    }
}

pub(crate) fn resize(id: u64, width: f64, height: f64) {
    unsafe {
        moth_resize_chrome(id, width, height);
    }
}

pub(crate) fn update(id: u64, json: &str) {
    if let Ok(json) = CString::new(json) {
        unsafe {
            moth_update_chrome(id, json.as_ptr());
        }
    }
}

pub(crate) fn focus_address(id: u64) {
    unsafe {
        moth_focus_address(id);
    }
}
pub(crate) fn focus_switcher(id: u64) {
    unsafe {
        moth_focus_switcher(id);
    }
}

pub(crate) fn focus_new_tab(id: u64) {
    unsafe {
        moth_focus_new_tab(id);
    }
}

unsafe extern "C" {
    fn moth_page_attach(
        window: u64,
        id: u64,
        generation: u64,
        view: *mut c_void,
        settings: *const c_char,
    );
    fn moth_page_action(window: u64, id: u64, action: *const c_char);
    fn moth_page_layout(window: u64, id: u64, x: f64, y: f64, width: f64, height: f64);
    fn moth_page_visible(window: u64, id: u64, visible: bool);
    fn moth_page_zoom(window: u64, id: u64, zoom: f64, fit: bool);
    fn moth_remove_chrome(id: u64);
}
pub(crate) fn page_layout(window: u64, id: u64, bounds: (f64, f64, f64, f64)) {
    unsafe {
        moth_page_layout(window, id, bounds.0, bounds.1, bounds.2, bounds.3);
    }
}
pub(crate) fn page_visible(window: u64, id: u64, visible: bool) {
    unsafe {
        moth_page_visible(window, id, visible);
    }
}
pub(crate) fn page_zoom(window: u64, id: u64, zoom: f64, fit: bool) {
    unsafe {
        moth_page_zoom(window, id, zoom, fit);
    }
}
pub(crate) fn attach_page(
    window: u64,
    id: u64,
    generation: u64,
    view: &wry::WebView,
    settings: &crate::data::Settings,
) {
    use wry::WebViewExtMacOS;
    let native = view.webview();
    let pointer = (&*native) as *const _ as *mut c_void;
    let settings = CString::new(serde_json::to_string(settings).expect("settings JSON"))
        .expect("settings CString");
    unsafe {
        moth_page_attach(window, id, generation, pointer, settings.as_ptr());
    }
}
pub(crate) fn action(window: u64, id: u64, action: &str) {
    if let Ok(action) = CString::new(action) {
        unsafe {
            moth_page_action(window, id, action.as_ptr());
        }
    }
}
pub(crate) fn remove(id: u64) {
    unsafe {
        moth_remove_chrome(id);
    }
}

pub(crate) fn private_configuration(
    id: u64,
) -> objc2::rc::Retained<objc2_web_kit::WKWebViewConfiguration> {
    unsafe extern "C" {
        fn moth_private_configuration(id: u64) -> *mut objc2_web_kit::WKWebViewConfiguration;
    }
    // Swift returns a newly retained configuration with this window's ephemeral store.
    unsafe {
        objc2::rc::Retained::from_raw(moth_private_configuration(id))
            .expect("private configuration")
    }
}

unsafe extern "C" {
    fn moth_popup_merge(window: u64, popup: *const c_char, id: u64, generation: u64) -> bool;
    fn moth_page_operation(
        window: u64,
        id: u64,
        operation: *const c_char,
        argument: *const c_char,
        callback: extern "C" fn(*const c_char, *mut c_void),
        context: *mut c_void,
    );
    fn moth_page_evaluate(
        window: u64,
        id: u64,
        script: *const c_char,
        callback: extern "C" fn(*const c_char, *mut c_void),
        context: *mut c_void,
    );
}

pub(crate) fn merge_popup(window: u64, popup: &str, id: u64, generation: u64) -> bool {
    let Ok(popup) = CString::new(popup) else {
        return false;
    };
    unsafe { moth_popup_merge(window, popup.as_ptr(), id, generation) }
}

pub(crate) fn page_operation(
    window: u64,
    id: u64,
    operation: &str,
    argument: &str,
) -> Option<String> {
    extern "C" fn receive(value: *const c_char, context: *mut c_void) {
        if !value.is_null() {
            unsafe {
                *(context as *mut Option<String>) =
                    Some(CStr::from_ptr(value).to_string_lossy().into_owned());
            }
        }
    }
    let operation = CString::new(operation).ok()?;
    let argument = CString::new(argument).ok()?;
    let mut result = None;
    unsafe {
        moth_page_operation(
            window,
            id,
            operation.as_ptr(),
            argument.as_ptr(),
            receive,
            &mut result as *mut _ as *mut c_void,
        );
    }
    result
}

pub(crate) fn evaluate_page(
    window: u64,
    id: u64,
    script: &str,
    callback: impl Fn(String) + Send + 'static,
) -> wry::Result<()> {
    type Callback = Box<dyn Fn(String) + Send>;
    extern "C" fn receive(value: *const c_char, context: *mut c_void) {
        // Swift calls exactly once, including when the page disappears or evaluation fails.
        let callback = unsafe { Box::from_raw(context as *mut Callback) };
        let value = if value.is_null() {
            "null".into()
        } else {
            unsafe { CStr::from_ptr(value).to_string_lossy().into_owned() }
        };
        callback(value);
    }
    let script = CString::new(script)
        .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidInput, error))?;
    let callback: Box<Callback> = Box::new(Box::new(callback));
    unsafe {
        moth_page_evaluate(
            window,
            id,
            script.as_ptr(),
            receive,
            Box::into_raw(callback) as *mut c_void,
        );
    }
    Ok(())
}
