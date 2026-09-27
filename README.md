# Moth

Moth is a small macOS browser built to study how a browser shell works. Rust owns tabs, navigation, workspaces, history, and persistence. SwiftUI and AppKit draw the native browser controls, while [Wry](https://github.com/tauri-apps/wry) displays websites using macOS WebKit. Moth does not ship its own rendering engine or Chrome/Firefox extension system.

## What works

- Vertical tabs, workspaces, navigation, bookmarks, history, downloads, and session restore
- A native address bar and quick switcher
- An Arc-style ⌘T command bar: type a URL or search and press Return to open it in a new tab; press Return with an empty input for a blank tab; press Escape to dismiss it
- A clean new-tab canvas with a user-selected local photo. The bottom-right control lets you choose, reposition, or remove it. Horizontal and vertical sliders adjust the crop, which is saved across restarts. PNG, JPEG, GIF, WebP, and HEIC are supported (up to 30 MB).
- The photo continues behind the translucent native sidebar and toolbar; navigation buttons have native Liquid Glass outlines on macOS 26 or later

The web content area on a blank tab contains no heading, instructions, shortcuts, bookmarks, or recent-page list. Library content remains accessible through the sidebar.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| New tab command bar | ⌘T |
| Address or search | ⌘L |
| Quick switcher | ⌘K |
| Close / reopen tab | ⌘W / ⌘⇧T |
| Go to tab 1–8 / last tab | ⌘1–8 / ⌘9 |
| Next / previous tab | ⌘⌥→ / ⌘⌥← |
| Back / forward / reload | ⌘[ / ⌘] / ⌘R |
| Bookmark page | ⌘D |
| Bookmarks / history / downloads | ⌘⌥B / ⌘Y / ⌘⇧J |

## Build and run

You need a Rust toolchain, Xcode command-line tools, and macOS 26 or later. Run `cargo run` for development, or build the app bundle:

```sh
sh scripts/build-app.sh
open target/release/Moth.app
```

The bundle is signed locally with an ad hoc signature. It is not notarized for distribution.

```sh
cargo fmt -- --check
cargo test
```

## Where to study the code

| Path | Purpose |
| --- | --- |
| `src/main.rs`, `src/app.rs` | Startup, event loop, window, keyboard menu |
| `src/browser.rs` | Tabs, webviews, commands, photo loading, state updates |
| `src/protocol.rs`, `src/native_chrome.rs` | Message types and Rust ↔ Swift bridge |
| `native/Chrome.swift`, `build.rs` | Native sidebar, toolbar, command bar, photo picker, Swift build |
| `src/address.rs`, `src/data.rs`, `src/downloads.rs` | URL resolution, saved browser data, download naming |
| `ui/shell.*` | Blank-tab photo surface and library panels |
| `scripts/build-app.sh` | macOS app packaging |
| `docs/ARCHITECTURE.md` | Data flow and a guided code reading path |

Start with [the architecture guide](docs/ARCHITECTURE.md), then follow one user action from `native/Chrome.swift` through `src/protocol.rs` and `src/browser.rs`.
