#[cfg(target_os = "macos")]
fn main() {
    use std::{env, path::PathBuf, process::Command};

    let out = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let mut compiler = Command::new("swiftc");
    if env::var("PROFILE").as_deref() == Ok("release") {
        compiler.args(["-O", "-whole-module-optimization"]);
    }
    let status = compiler
        .args([
            "-emit-library",
            "-static",
            "-parse-as-library",
            "-module-name",
            "MothChrome",
        ])
        .arg("native/Chrome.swift")
        .arg("native/BrowserFeatures.swift")
        .arg("native/DeveloperTools.swift")
        .arg("native/AdBlocker.swift")
        .arg("native/PictureInPicture.swift")
        .arg("native/BrowserPopup.swift")
        .arg("native/LocalProject.swift")
        .arg("native/ProjectProcess.swift")
        .arg("native/LocalProjects.swift")
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
    println!("cargo:rerun-if-changed=native/BrowserFeatures.swift");
    println!("cargo:rerun-if-changed=native/DeveloperTools.swift");
    println!("cargo:rerun-if-changed=native/AdBlocker.swift");
    println!("cargo:rerun-if-changed=native/PictureInPicture.swift");
    println!("cargo:rerun-if-changed=native/BrowserPopup.swift");
    println!("cargo:rerun-if-changed=native/LocalProject.swift");
    println!("cargo:rerun-if-changed=native/ProjectProcess.swift");
    println!("cargo:rerun-if-changed=native/LocalProjects.swift");
}

#[cfg(not(target_os = "macos"))]
fn main() {}
