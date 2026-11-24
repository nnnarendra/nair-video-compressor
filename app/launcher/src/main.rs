#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const APP_EXE: &[u8] = include_bytes!(env!("NAIR_APP_EXE"));
const WV2_DLL: &[u8] = include_bytes!(env!("NAIR_WV2_DLL"));
const BUILD_STAMP: &str = env!("NAIR_BUILD_STAMP");

fn runtime_dir() -> PathBuf {
    let base = env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(env::temp_dir);
    base.join("nair-video-compressor")
        .join("runtime")
        .join(BUILD_STAMP)
}

fn ensure_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Ok(meta) = fs::metadata(path) {
        if meta.len() == bytes.len() as u64 {
            return Ok(());
        }
    }
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, bytes).map_err(|e| format!("Failed to write {}: {}", path.display(), e))?;
    if path.exists() {
        let _ = fs::remove_file(path);
    }
    fs::rename(&tmp, path).map_err(|e| format!("Failed to move {}: {}", path.display(), e))
}

fn main() {
    let dir = runtime_dir();
    if let Err(err) = fs::create_dir_all(&dir) {
        eprintln!("Failed to create runtime directory: {}", err);
        std::process::exit(1);
    }

    let app_path = dir.join("nair-video-compressor.exe");
    let dll_path = dir.join("WebView2Loader.dll");

    if let Err(err) = ensure_file(&dll_path, WV2_DLL).and_then(|_| ensure_file(&app_path, APP_EXE))
    {
        eprintln!("{}", err);
        std::process::exit(1);
    }

    let mut cmd = Command::new(&app_path);
    cmd.current_dir(&dir);

    if let Ok(self_exe) = env::current_exe() {
        if let Some(portable_dir) = self_exe.parent() {
            cmd.env("NAIR_PORTABLE_DIR", portable_dir);
        }
    }

    if let Err(err) = cmd.spawn() {
        eprintln!("Failed to launch application: {}", err);
        std::process::exit(1);
    }
}
