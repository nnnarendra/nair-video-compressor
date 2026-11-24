#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod ffmpeg;
mod settings;

use ffmpeg::{CompressionState, FfmpegStatus, VideoItemInfo};
use serde_json::{json, Value};
use settings::AppSettings;
use std::path::Path;
use std::sync::Arc;
use tauri::{AppHandle, State};
use tauri_plugin_opener::OpenerExt;

#[tauri::command]
fn get_app_info() -> Value {
    json!({
        "name": env!("CARGO_PKG_NAME"),
        "version": env!("CARGO_PKG_VERSION"),
    })
}

#[tauri::command]
fn load_settings() -> AppSettings {
    settings::load_settings()
}

#[tauri::command]
fn save_settings(settings: AppSettings) -> Result<(), String> {
    settings::save_settings(&settings)
}

#[tauri::command]
async fn check_ffmpeg(test_gpu: Option<bool>) -> Result<FfmpegStatus, String> {
    let run_gpu = test_gpu.unwrap_or(true);
    tokio::task::spawn_blocking(move || ffmpeg::check_ffmpeg_status(run_gpu))
        .await
        .map_err(|e| format!("Failed to check FFmpeg status: {}", e))
}

#[tauri::command]
async fn download_ffmpeg(app: AppHandle) -> Result<FfmpegStatus, String> {
    ffmpeg::download_ffmpeg(&app).await
}

#[tauri::command]
async fn scan_inputs(paths: Vec<String>) -> Result<Vec<VideoItemInfo>, String> {
    tokio::task::spawn_blocking(move || ffmpeg::scan_inputs(paths))
        .await
        .map_err(|e| format!("Failed to scan video files: {}", e))
}

#[tauri::command]
async fn start_compression(
    app: AppHandle,
    state: State<'_, Arc<CompressionState>>,
    items: Vec<VideoItemInfo>,
    settings: AppSettings,
) -> Result<(), String> {
    ffmpeg::run_compression_batch(app, state.inner().clone(), items, settings).await
}

#[tauri::command]
fn cancel_compression(state: State<'_, Arc<CompressionState>>) -> Result<(), String> {
    ffmpeg::cancel_active_compression(state.inner())
}

#[tauri::command]
fn open_folder(app: AppHandle, path: String) -> Result<(), String> {
    let clean = path.trim().trim_matches('"');
    if clean.is_empty() {
        return Err("Folder path is empty.".to_string());
    }
    let target = Path::new(clean);
    let folder = if target.is_file() {
        target.parent().unwrap_or(target)
    } else {
        target
    };
    if !folder.exists() {
        return Err(format!("Folder does not exist yet: {}", folder.display()));
    }
    app.opener()
        .open_path(folder.to_string_lossy().as_ref(), None::<&str>)
        .map_err(|e| format!("Failed to open folder: {}", e))
}

pub fn run() {
    tauri::Builder::default()
        .manage(Arc::new(CompressionState::default()))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            get_app_info,
            load_settings,
            save_settings,
            check_ffmpeg,
            download_ffmpeg,
            scan_inputs,
            start_compression,
            cancel_compression,
            open_folder,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn main() {
    run();
}
