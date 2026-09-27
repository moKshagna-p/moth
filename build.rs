#[cfg(target_os = "macos")]
fn main() {
    use std::{env, path::PathBuf, process::Command};

    let out = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let status = Command::new("swiftc")
        .args([
            "-emit-library",
            "-static",
            "-parse-as-library",
            "-module-name",
            "MothChrome",
        ])
        .arg("native/Chrome.swift")
        .arg("-o")
        .arg(out.join("libmoth_chrome.a"))
        .status()
        .expect("Swift compiler is required for Moth's native macOS interface");
    assert!(status.success(), "Native macOS interface failed to compile");
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=moth_chrome");
    println!("cargo:rustc-link-lib=framework=SwiftUI");
    println!("cargo:rustc-link-lib=framework=AppKit");
    println!("cargo:rustc-link-arg=-L/usr/lib/swift");
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    println!("cargo:rerun-if-changed=native/Chrome.swift");
}

#[cfg(not(target_os = "macos"))]
fn main() {}
