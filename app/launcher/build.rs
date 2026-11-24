use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-env-changed=NAIR_APP_EXE");
    println!("cargo:rerun-if-env-changed=NAIR_WV2_DLL");
    println!("cargo:rerun-if-env-changed=NAIR_BUILD_STAMP");

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let icon_path = manifest_dir
        .join("..")
        .join("src-tauri")
        .join("icons")
        .join("icon.ico");
    println!("cargo:rerun-if-changed={}", icon_path.display());

    if icon_path.is_file() {
        let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
        let rc_path = out_dir.join("launcher.rc");
        let res_path = out_dir.join("launcher.res");
        let icon_escaped = icon_path.to_string_lossy().replace('\\', "/");
        let rc_content = format!("1 ICON \"{}\"\n", icon_escaped);
        if fs::write(&rc_path, rc_content).is_ok() {
            let status = Command::new("windres")
                .args([
                    rc_path.to_string_lossy().as_ref(),
                    "-O",
                    "coff",
                    "-o",
                    res_path.to_string_lossy().as_ref(),
                ])
                .status();
            if matches!(status, Ok(s) if s.success()) && res_path.is_file() {
                println!("cargo:rustc-link-arg={}", res_path.display());
            }
        }
    }
}
