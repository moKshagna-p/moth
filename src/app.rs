use crate::{browser::Browser, protocol::BrowserEvent};
#[cfg(target_os = "macos")]
use muda::{
    accelerator::{Accelerator, Code, Modifiers},
    Menu, MenuEvent, MenuItem, Submenu,
};
use tao::{
    dpi::LogicalSize,
    event::{Event, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy},
    window::WindowBuilder,
};

pub(crate) fn run() {
    let event_loop = EventLoopBuilder::<BrowserEvent>::with_user_event().build();
    #[cfg(target_os = "macos")]
    let _menu = setup_menu(event_loop.create_proxy());
    let window = WindowBuilder::new()
        .with_title("Moth")
        .with_inner_size(LogicalSize::new(1200.0, 800.0))
        .build(&event_loop)
        .expect("Cannot create browser window");
    let mut browser =
        Browser::new(window, event_loop.create_proxy()).expect("Cannot start browser");
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        match event {
            Event::WindowEvent {
                event: WindowEvent::CloseRequested,
                ..
            } => {
                *control_flow = ControlFlow::Exit;
            }
            Event::WindowEvent {
                event: WindowEvent::Resized(_),
                ..
            } => browser.resize(),
            Event::UserEvent(event) => browser.handle_event(event),
            _ => {}
        }
    });
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
    let file =
        Submenu::with_items("File", true, &[&new_tab, &reopen_tab, &close_tab]).expect("File menu");
    let view = Submenu::with_items(
        "View",
        true,
        &[
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
    menu.append_items(&[&file, &view]).expect("Browser menu");
    menu.init_for_nsapp();
    MenuEvent::set_event_handler(Some(move |event| {
        let _ = proxy.send_event(BrowserEvent::Menu(event));
    }));
    menu
}
