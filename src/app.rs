use crate::{
    browser::Browser,
    protocol::{BrowserEvent, BrowserProxy, Command},
};
#[cfg(target_os = "macos")]
use muda::{
    accelerator::{Accelerator, Code, Modifiers},
    Menu, MenuEvent, MenuItem, Submenu,
};
use std::time::{Duration, Instant};
use tao::{
    dpi::LogicalSize,
    event::{Event, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy},
    window::WindowBuilder,
};

pub(crate) fn run() {
    let event_loop = EventLoopBuilder::<BrowserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();
    #[cfg(target_os = "macos")]
    let _menu = setup_menu(proxy.clone());
    let window = make_window(&event_loop);
    let browser = Browser::new(
        window,
        BrowserProxy {
            id: 1,
            proxy: proxy.clone(),
        },
        false,
        None,
    )
    .expect("Cannot start browser");
    let mut windows = std::collections::BTreeMap::from([(1_u64, browser)]);
    let mut focused = 1;
    let mut next_id = 2;
    let mut next_reap = Instant::now() + Duration::from_secs(60);
    event_loop.run(move |event, target, control_flow| {
        let mut routed = None;
        let mut create = None;
        let mut opened_urls = Vec::new();
        match event {
            Event::WindowEvent {
                window_id,
                event: WindowEvent::CloseRequested,
                ..
            } => {
                if let Some(key) = windows
                    .iter()
                    .find(|(_, b)| b.window.id() == window_id)
                    .map(|(k, _)| *k)
                {
                    // Preserve the final normal window for startup restore, but
                    // exclude a closed window when other normal windows survive.
                    if windows.values().filter(|b| !b.private_mode).count() <= 1 {
                        persist(&mut windows, true);
                    }
                    #[cfg(target_os = "macos")]
                    crate::native_chrome::remove(key);
                    windows.remove(&key);
                    persist(&mut windows, true);
                    if windows.is_empty() {
                        *control_flow = ControlFlow::Exit;
                        return;
                    }
                    focused = *windows.keys().next().unwrap();
                }
            }
            Event::LoopDestroyed => {
                persist(&mut windows, true);
                return;
            }
            Event::WindowEvent {
                window_id, event, ..
            } => {
                if let Some((key, browser)) =
                    windows.iter_mut().find(|(_, b)| b.window.id() == window_id)
                {
                    match event {
                        WindowEvent::Resized(_) => browser.resize(),
                        WindowEvent::Focused(true) => focused = *key,
                        _ => {}
                    }
                }
            }
            Event::Opened { urls } => {
                opened_urls = urls
                    .into_iter()
                    .filter(|u| matches!(u.scheme(), "http" | "https"))
                    .collect();
                if !opened_urls.is_empty() && !windows.values().any(|b| !b.private_mode) {
                    create = Some(false);
                }
            }
            Event::UserEvent(BrowserEvent::Routed(key, event)) => routed = Some((key, *event)),
            Event::UserEvent(event) => routed = Some((focused, event)),
            _ => {}
        }
        if let Some((key, event)) = routed {
            match event {
                BrowserEvent::Command(Command::NewWindow { private }) => create = Some(private),
                #[cfg(target_os = "macos")]
                BrowserEvent::Menu(ref menu)
                    if menu.id.0 == "new_window" || menu.id.0 == "private_window" =>
                {
                    create = Some(menu.id.0 == "private_window")
                }
                BrowserEvent::Command(Command::ClearSiteData)
                    if windows.values().filter(|b| !b.private_mode).count() > 1
                        && windows.get(&key).is_some_and(|b| !b.private_mode) =>
                {
                    if let Some(browser) = windows.get_mut(&key) {
                        browser.error =
                            Some("Close other normal windows before clearing website data.".into());
                        browser.refresh();
                    }
                }
                event => {
                    if let Some(browser) = windows.get_mut(&key) {
                        browser.handle_event(event);
                    }
                    if let Some(data) = windows
                        .get(&key)
                        .filter(|b| !b.private_mode)
                        .map(|b| b.data.clone())
                    {
                        for browser in windows.values_mut() {
                            browser.sync_data(&data);
                        }
                    }
                }
            }
        }
        if let Some(private) = create {
            let shared = windows
                .values()
                .find(|b| !b.private_mode)
                .map(|b| b.data.clone());
            let window = make_window(target);
            match Browser::new(
                window,
                BrowserProxy {
                    id: next_id,
                    proxy: proxy.clone(),
                },
                private,
                shared,
            ) {
                Ok(browser) => {
                    windows.insert(next_id, browser);
                    focused = next_id;
                    next_id += 1;
                }
                Err(error) => {
                    if let Some(browser) = windows.get_mut(&focused) {
                        browser.error = Some(error.to_string());
                        browser.refresh();
                    }
                }
            }
        }
        if !opened_urls.is_empty() {
            if let Some(key) = windows
                .iter()
                .find(|(_, b)| !b.private_mode)
                .map(|(k, _)| *k)
            {
                let browser = windows.get_mut(&key).unwrap();
                for url in opened_urls {
                    browser.handle_event(BrowserEvent::OpenTab(url.to_string()));
                }
                browser.window.set_focus();
                focused = key;
                let data = browser.data.clone();
                for browser in windows.values_mut() {
                    browser.sync_data(&data);
                }
            }
        }
        if Instant::now() >= next_reap {
            for browser in windows.values_mut() {
                browser.reap_tabs();
            }
            next_reap = Instant::now() + Duration::from_secs(60);
        }
        persist(&mut windows, false);
        let deadline = windows
            .values()
            .filter_map(Browser::save_deadline)
            .min()
            .map_or(next_reap, |due| due.min(next_reap));
        *control_flow = ControlFlow::WaitUntil(deadline);
    });
}

fn make_window(
    target: &tao::event_loop::EventLoopWindowTarget<BrowserEvent>,
) -> tao::window::Window {
    WindowBuilder::new()
        .with_title("Moth")
        .with_inner_size(LogicalSize::new(1200.0, 800.0))
        .with_min_inner_size(LogicalSize::new(640.0, 480.0))
        .build(target)
        .expect("Cannot create browser window")
}

fn persist(windows: &mut std::collections::BTreeMap<u64, Browser>, force: bool) {
    if !force
        && !windows
            .values()
            .any(|b| b.save_deadline().is_some_and(|due| due <= Instant::now()))
    {
        return;
    }
    let Some(primary) = windows.values().find(|b| !b.private_mode) else {
        for b in windows.values_mut() {
            b.save_due = None;
        }
        return;
    };
    let mut data = primary.data.clone();
    data.session_tabs = windows.values().flat_map(Browser::sessions).collect();
    data.active_tab_index = primary.active_index();
    data.active_workspace = primary.active_workspace();
    let result = data.save(&primary.data_path);
    for browser in windows.values_mut() {
        browser.save_due = None;
        if let Err(ref error) = result {
            browser.error = Some(format!("Could not save browser data: {error}"));
            browser.refresh();
        }
    }
}

#[cfg(target_os = "macos")]
fn setup_menu(proxy: EventLoopProxy<BrowserEvent>) -> Menu {
    let shortcut = |id, label, code, modifiers| {
        MenuItem::with_id(id, label, true, Some(Accelerator::new(modifiers, code)))
    };
    let command = Modifiers::META;
    let address = shortcut("address", "Open Location", Code::KeyL, command);
    let switcher = shortcut("switcher", "Quick Switch", Code::KeyK, command);
    let new_tab = shortcut("new_tab", "New Tab", Code::KeyT, command);
    let reopen_tab = shortcut(
        "reopen_tab",
        "Reopen Closed Tab",
        Code::KeyT,
        command | Modifiers::SHIFT,
    );
    let close_tab = shortcut("close_tab", "Close Tab", Code::KeyW, command);
    let next_tab = shortcut(
        "next_tab",
        "Next Tab",
        Code::ArrowRight,
        command | Modifiers::ALT,
    );
    let previous_tab = shortcut(
        "previous_tab",
        "Previous Tab",
        Code::ArrowLeft,
        command | Modifiers::ALT,
    );
    let numbered_tabs: Vec<MenuItem> = (1..=9)
        .map(|number| {
            MenuItem::with_id(
                format!("tab_{number}"),
                format!("Go to Tab {number}"),
                true,
                Some(Accelerator::new(
                    command,
                    match number {
                        1 => Code::Digit1,
                        2 => Code::Digit2,
                        3 => Code::Digit3,
                        4 => Code::Digit4,
                        5 => Code::Digit5,
                        6 => Code::Digit6,
                        7 => Code::Digit7,
                        8 => Code::Digit8,
                        _ => Code::Digit9,
                    },
                )),
            )
        })
        .collect();
    let back = shortcut("back", "Back", Code::BracketLeft, command);
    let forward = shortcut("forward", "Forward", Code::BracketRight, command);
    let reload = shortcut("reload", "Reload", Code::KeyR, command);
    let bookmark = shortcut("bookmark", "Bookmark This Page", Code::KeyD, command);
    let history = shortcut("history", "History", Code::KeyY, command);
    let bookmarks = shortcut(
        "bookmarks",
        "Bookmarks",
        Code::KeyB,
        command | Modifiers::ALT,
    );
    let downloads = shortcut(
        "downloads",
        "Downloads",
        Code::KeyJ,
        command | Modifiers::SHIFT,
    );
    let new_window = shortcut("new_window", "New Window", Code::KeyN, command);
    let private_window = shortcut(
        "private_window",
        "New Private Window",
        Code::KeyN,
        command | Modifiers::SHIFT,
    );
    let print = shortcut("print", "Print / Save as PDF…", Code::KeyP, command);
    let settings = shortcut("settings", "Settings…", Code::Comma, command);
    let inspect = shortcut(
        "inspect",
        "Web Inspector",
        Code::KeyI,
        command | Modifiers::ALT,
    );
    let screenshot = shortcut(
        "screenshot",
        "Save Viewport Screenshot…",
        Code::KeyS,
        command | Modifiers::SHIFT,
    );
    let find = shortcut("find", "Find in Page…", Code::KeyF, command);
    let zoom_in = shortcut("zoom_in", "Zoom In", Code::Equal, command);
    let zoom_out = shortcut("zoom_out", "Zoom Out", Code::Minus, command);
    let zoom_reset = shortcut("zoom_reset", "Actual Size", Code::Digit0, command);
    let file = Submenu::with_items(
        "File",
        true,
        &[
            &new_window,
            &private_window,
            &new_tab,
            &reopen_tab,
            &close_tab,
            &print,
            &settings,
        ],
    )
    .expect("File menu");
    let view = Submenu::with_items(
        "View",
        true,
        &[
            &inspect,
            &screenshot,
            &find,
            &zoom_in,
            &zoom_out,
            &zoom_reset,
            &address,
            &switcher,
            &back,
            &forward,
            &reload,
            &bookmark,
            &bookmarks,
            &history,
            &downloads,
            &next_tab,
            &previous_tab,
        ],
    )
    .expect("View menu");
    for item in &numbered_tabs {
        view.append(item).expect("Numbered tab shortcut");
    }
    let menu = Menu::new();
    let edit = Submenu::with_items(
        "Edit",
        true,
        &[
            &muda::PredefinedMenuItem::undo(None),
            &muda::PredefinedMenuItem::redo(None),
            &muda::PredefinedMenuItem::cut(None),
            &muda::PredefinedMenuItem::copy(None),
            &muda::PredefinedMenuItem::paste(None),
            &muda::PredefinedMenuItem::select_all(None),
        ],
    )
    .expect("Edit menu");
    let application = Submenu::with_items(
        "Moth",
        true,
        &[
            &muda::PredefinedMenuItem::about(None, None),
            &muda::PredefinedMenuItem::quit(None),
        ],
    )
    .expect("Application menu");
    menu.append_items(&[&application, &file, &edit, &view])
        .expect("Browser menu");
    menu.init_for_nsapp();
    MenuEvent::set_event_handler(Some(move |event| {
        let _ = proxy.send_event(BrowserEvent::Menu(event));
    }));
    menu
}
