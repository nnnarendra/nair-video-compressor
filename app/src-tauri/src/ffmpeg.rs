use crate::settings::{self, AppSettings};
use futures_util::StreamExt;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command as StdCommand, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};
use tokio::io::AsyncReadExt;
use tokio::process::Command as TokioCommand;
use zip::ZipArchive;

const FFMPEG_ESSENTIALS_URL: &str =
    "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip";
const VIDEO_EXTENSIONS: [&str; 5] = ["mp4", "mov", "mkv", "avi", "webm"];

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

fn apply_no_window_std(cmd: &mut StdCommand) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    {
        let _ = cmd;
    }
}

fn apply_no_window_tokio(cmd: &mut TokioCommand) {
    #[cfg(windows)]
    {
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    {
        let _ = cmd;
    }
}

#[derive(Debug, Default)]
pub struct CompressionState {
    pub is_running: AtomicBool,
    pub cancel_flag: AtomicBool,
    pub active_pid: Mutex<Option<u32>>,
}

struct RunningGuard {
    state: Arc<CompressionState>,
}

impl RunningGuard {
    fn acquire(state: Arc<CompressionState>) -> Result<Self, String> {
        state
            .is_running
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .map_err(|_| "Compression is already running.".to_string())?;
        state.cancel_flag.store(false, Ordering::SeqCst);
        if let Ok(mut pid) = state.active_pid.lock() {
            *pid = None;
        }
        Ok(Self { state })
    }
}

impl Drop for RunningGuard {
    fn drop(&mut self) {
        if let Ok(mut pid) = self.state.active_pid.lock() {
            *pid = None;
        }
        self.state.cancel_flag.store(false, Ordering::SeqCst);
        self.state.is_running.store(false, Ordering::SeqCst);
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FfmpegStatus {
    pub available: bool,
    pub source: String,
    pub ffmpeg_path: Option<String>,
    pub version: Option<String>,
    pub gpu_available: bool,
}

impl Default for FfmpegStatus {
    fn default() -> Self {
        Self {
            available: false,
            source: "missing".to_string(),
            ffmpeg_path: None,
            version: None,
            gpu_available: false,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ResolvedBinaries {
    pub ffmpeg: PathBuf,
    pub ffprobe: Option<PathBuf>,
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VideoItemInfo {
    pub path: String,
    pub file_name: String,
    pub size_bytes: u64,
    pub duration_secs: f64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PresetSpec {
    pub codec: &'static str,
    pub crf: u8,
    pub ffmpeg_preset: &'static str,
    pub audio_bitrate: &'static str,
    pub effective_resolusi: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProgressSample {
    pub elapsed_secs: f64,
    pub fps: Option<f64>,
    pub speed: Option<f64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadProgressEvent {
    pub stage: String,
    pub downloaded_bytes: u64,
    pub total_bytes: Option<u64>,
    pub percent: Option<f64>,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GpuFallbackEvent {
    pub reason: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompressionProgressEvent {
    pub path: String,
    pub index: usize,
    pub total: usize,
    pub percent: f64,
    pub elapsed_secs: f64,
    pub duration_secs: f64,
    pub fps: Option<f64>,
    pub speed: Option<f64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompressionItemDoneEvent {
    pub path: String,
    pub index: usize,
    pub output_path: String,
    pub before_bytes: u64,
    pub after_bytes: u64,
    pub saved_percent: f64,
    pub used_gpu: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompressionItemErrorEvent {
    pub path: String,
    pub index: usize,
    pub error: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompressionItemCancelledEvent {
    pub path: String,
    pub index: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompressionFinishedEvent {
    pub cancelled: bool,
    pub total_items: usize,
    pub succeeded: usize,
    pub failed: usize,
    pub total_before_bytes: u64,
    pub total_after_bytes: u64,
}

fn binary_names() -> (&'static str, &'static str) {
    #[cfg(windows)]
    {
        ("ffmpeg.exe", "ffprobe.exe")
    }
    #[cfg(not(windows))]
    {
        ("ffmpeg", "ffprobe")
    }
}

fn find_in_system_path(bin_name: &str) -> Option<PathBuf> {
    let path_var = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path_var) {
        let candidate = dir.join(bin_name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn sibling_ffprobe(ffmpeg_path: &Path, ffprobe_name: &str) -> Option<PathBuf> {
    if let Some(parent) = ffmpeg_path.parent() {
        let sibling = parent.join(ffprobe_name);
        if sibling.is_file() {
            return Some(sibling);
        }
    }
    find_in_system_path(ffprobe_name)
}

fn portable_base_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("NAIR_PORTABLE_DIR") {
        let p = PathBuf::from(dir);
        if !p.as_os_str().is_empty() {
            return Some(p);
        }
    }
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
}

fn resolve_with_source(ffmpeg: PathBuf, ffprobe_name: &str, source: &str) -> ResolvedBinaries {
    let ffprobe = sibling_ffprobe(&ffmpeg, ffprobe_name);
    ResolvedBinaries {
        ffmpeg,
        ffprobe,
        source: source.to_string(),
    }
}

pub fn find_binaries() -> Option<ResolvedBinaries> {
    let (ffmpeg_name, ffprobe_name) = binary_names();

    if let Some(exe_dir) = portable_base_dir() {
        let local_bin = exe_dir.join("bin").join(ffmpeg_name);
        if local_bin.is_file() {
            return Some(resolve_with_source(local_bin, ffprobe_name, "local"));
        }

        let beside_exe = exe_dir.join(ffmpeg_name);
        if beside_exe.is_file() {
            return Some(resolve_with_source(beside_exe, ffprobe_name, "local"));
        }
    }

    let appdata_bin = settings::appdata_dir().join("bin").join(ffmpeg_name);
    if appdata_bin.is_file() {
        return Some(resolve_with_source(appdata_bin, ffprobe_name, "appdata"));
    }

    find_in_system_path(ffmpeg_name)
        .map(|path_ffmpeg| resolve_with_source(path_ffmpeg, ffprobe_name, "path"))
}

fn read_ffmpeg_version(ffmpeg: &Path) -> Option<String> {
    let mut cmd = StdCommand::new(ffmpeg);
    cmd.arg("-version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    apply_no_window_std(&mut cmd);

    let out = cmd.output().ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    text.lines().next().map(|s| s.trim().to_string())
}

pub fn test_nvenc(ffmpeg: &Path) -> bool {
    let tmp = std::env::temp_dir().join(format!("nair-gpu-test-nvenc-{}.mp4", std::process::id()));
    let _ = fs::remove_file(&tmp);

    let mut cmd = StdCommand::new(ffmpeg);
    cmd.args([
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "lavfi",
        "-i",
        "color=c=black:s=128x128:d=0.1",
        "-c:v",
        "h264_nvenc",
        "-preset",
        "p1",
        "-f",
        "mp4",
    ])
    .arg(&tmp)
    .stdin(Stdio::null())
    .stdout(Stdio::null())
    .stderr(Stdio::null());
    apply_no_window_std(&mut cmd);

    let ok = cmd
        .status()
        .map(|s| s.success() && tmp.is_file())
        .unwrap_or(false);
    let _ = fs::remove_file(&tmp);
    ok
}

pub fn check_ffmpeg_status(test_gpu: bool) -> FfmpegStatus {
    let Some(bins) = find_binaries() else {
        return FfmpegStatus::default();
    };

    let version = read_ffmpeg_version(&bins.ffmpeg);
    let gpu_available = if test_gpu {
        test_nvenc(&bins.ffmpeg)
    } else {
        false
    };

    FfmpegStatus {
        available: true,
        source: bins.source,
        ffmpeg_path: Some(bins.ffmpeg.to_string_lossy().to_string()),
        version,
        gpu_available,
    }
}

fn resolve_writable_bin_dir() -> Result<PathBuf, String> {
    if let Some(exe_dir) = portable_base_dir() {
        let local_bin = exe_dir.join("bin");
        if settings::is_dir_writable(&local_bin) {
            return Ok(local_bin);
        }
    }

    let appdata_bin = settings::appdata_dir().join("bin");
    fs::create_dir_all(&appdata_bin)
        .map_err(|e| format!("Failed to create bin folder in AppData: {}", e))?;
    Ok(appdata_bin)
}

fn emit_download_progress(
    app: &AppHandle,
    stage: &str,
    downloaded_bytes: u64,
    total_bytes: Option<u64>,
    message: &str,
) {
    let percent = total_bytes.and_then(|total| {
        if total > 0 {
            Some(((downloaded_bytes as f64 / total as f64) * 1000.0).round() / 10.0)
        } else {
            None
        }
    });
    let _ = app.emit(
        "ffmpeg-download-progress",
        DownloadProgressEvent {
            stage: stage.to_string(),
            downloaded_bytes,
            total_bytes,
            percent,
            message: message.to_string(),
        },
    );
}

fn extract_ffmpeg_binaries_from_zip(zip_path: &Path, target_dir: &Path) -> Result<(), String> {
    let file =
        fs::File::open(zip_path).map_err(|e| format!("Failed to open FFmpeg zip archive: {}", e))?;
    let mut archive =
        ZipArchive::new(file).map_err(|e| format!("Corrupted FFmpeg zip archive: {}", e))?;

    fs::create_dir_all(target_dir)
        .map_err(|e| format!("Failed to create target FFmpeg folder: {}", e))?;

    let mut found_ffmpeg = false;
    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("Failed to read zip entry: {}", e))?;
        if entry.is_dir() {
            continue;
        }
        let Some(file_name) = Path::new(entry.name())
            .file_name()
            .and_then(|n| n.to_str())
        else {
            continue;
        };

        let lower = file_name.to_ascii_lowercase();
        if lower != "ffmpeg.exe" && lower != "ffprobe.exe" {
            continue;
        }

        let dest_path = target_dir.join(&lower);
        let mut out = fs::File::create(&dest_path)
            .map_err(|e| format!("Failed to write {}: {}", dest_path.display(), e))?;
        std::io::copy(&mut entry, &mut out)
            .map_err(|e| format!("Failed to extract {}: {}", lower, e))?;
        if lower == "ffmpeg.exe" {
            found_ffmpeg = true;
        }
    }

    if !found_ffmpeg {
        return Err("ffmpeg.exe was not found in the downloaded archive.".to_string());
    }
    Ok(())
}

pub async fn download_ffmpeg(app: &AppHandle) -> Result<FfmpegStatus, String> {
    emit_download_progress(
        app,
        "downloading",
        0,
        None,
        "Connecting to gyan.dev...",
    );

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(600))
        .build()
        .map_err(|e| {
            let msg = format!("Failed to initialize HTTP client: {}", e);
            emit_download_progress(app, "error", 0, None, &msg);
            msg
        })?;

    let resp = client
        .get(FFMPEG_ESSENTIALS_URL)
        .send()
        .await
        .and_then(|r| r.error_for_status())
        .map_err(|e| {
            let msg = format!("Failed to download FFmpeg: {}", e);
            emit_download_progress(app, "error", 0, None, &msg);
            msg
        })?;

    let total_bytes = resp.content_length();
    let temp_zip = std::env::temp_dir().join(format!(
        "nair-ffmpeg-essentials-{}.zip",
        std::process::id()
    ));
    let _ = fs::remove_file(&temp_zip);

    let mut out_file = fs::File::create(&temp_zip).map_err(|e| {
        let msg = format!("Failed to create temporary file: {}", e);
        emit_download_progress(app, "error", 0, total_bytes, &msg);
        msg
    })?;

    let mut stream = resp.bytes_stream();
    let mut downloaded: u64 = 0;
    let mut last_emit_bytes: u64 = 0;

    while let Some(chunk_res) = stream.next().await {
        let chunk = match chunk_res {
            Ok(c) => c,
            Err(e) => {
                let _ = fs::remove_file(&temp_zip);
                let msg = format!("Connection interrupted while downloading FFmpeg: {}", e);
                emit_download_progress(app, "error", downloaded, total_bytes, &msg);
                return Err(msg);
            }
        };

        if let Err(e) = out_file.write_all(&chunk) {
            let _ = fs::remove_file(&temp_zip);
            let msg = format!("Failed to write download file: {}", e);
            emit_download_progress(app, "error", downloaded, total_bytes, &msg);
            return Err(msg);
        }

        downloaded += chunk.len() as u64;
        if downloaded.saturating_sub(last_emit_bytes) >= 256 * 1024
            || total_bytes.map(|t| downloaded >= t).unwrap_or(false)
        {
            last_emit_bytes = downloaded;
            emit_download_progress(
                app,
                "downloading",
                downloaded,
                total_bytes,
                "Downloading FFmpeg Essentials...",
            );
        }
    }
    drop(out_file);

    emit_download_progress(
        app,
        "extracting",
        downloaded,
        total_bytes,
        "Extracting ffmpeg.exe and ffprobe.exe...",
    );

    let target_dir = resolve_writable_bin_dir().map_err(|msg| {
        let _ = fs::remove_file(&temp_zip);
        emit_download_progress(app, "error", downloaded, total_bytes, &msg);
        msg
    })?;

    let zip_for_extract = temp_zip.clone();
    let extract_res = tokio::task::spawn_blocking(move || {
        extract_ffmpeg_binaries_from_zip(&zip_for_extract, &target_dir)
    })
    .await
    .map_err(|e| format!("Extraction task failed: {}", e))?;

    let _ = fs::remove_file(&temp_zip);
    if let Err(msg) = extract_res {
        emit_download_progress(app, "error", downloaded, total_bytes, &msg);
        return Err(msg);
    }

    let status = tokio::task::spawn_blocking(|| check_ffmpeg_status(true))
        .await
        .map_err(|e| format!("Failed to verify FFmpeg: {}", e))?;

    if !status.available {
        let msg = "FFmpeg was extracted but could not be executed.".to_string();
        emit_download_progress(app, "error", downloaded, total_bytes, &msg);
        return Err(msg);
    }

    emit_download_progress(
        app,
        "done",
        downloaded,
        total_bytes,
        "FFmpeg is ready.",
    );
    Ok(status)
}

fn is_supported_video(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|ext| VIDEO_EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

fn hms_to_secs(caps: &regex::Captures) -> Option<f64> {
    let h: f64 = caps[1].parse().ok()?;
    let m: f64 = caps[2].parse().ok()?;
    let s: f64 = caps[3].parse().ok()?;
    let frac: f64 = format!("0.{}", &caps[4]).parse().ok()?;
    Some((h * 3600.0) + (m * 60.0) + s + frac)
}

pub fn parse_duration_str(text: &str) -> Option<f64> {
    static RE_DURATION: OnceLock<Regex> = OnceLock::new();
    let re = RE_DURATION
        .get_or_init(|| Regex::new(r"Duration:\s*(\d+):(\d+):(\d+)\.(\d+)").unwrap());
    hms_to_secs(&re.captures(text)?)
}

pub fn parse_stats_line(line: &str) -> Option<ProgressSample> {
    static RE_TIME: OnceLock<Regex> = OnceLock::new();
    static RE_FPS: OnceLock<Regex> = OnceLock::new();
    static RE_SPEED: OnceLock<Regex> = OnceLock::new();

    let re_time =
        RE_TIME.get_or_init(|| Regex::new(r"time=(\d+):(\d+):(\d+)\.(\d+)").unwrap());
    let elapsed_secs = hms_to_secs(&re_time.captures(line)?)?;

    let re_fps = RE_FPS.get_or_init(|| Regex::new(r"fps=\s*([\d\.]+)").unwrap());
    let fps = re_fps
        .captures(line)
        .and_then(|c| c[1].parse::<f64>().ok());

    let re_speed = RE_SPEED.get_or_init(|| Regex::new(r"speed=\s*([\d\.]+)x").unwrap());
    let speed = re_speed
        .captures(line)
        .and_then(|c| c[1].parse::<f64>().ok());

    Some(ProgressSample {
        elapsed_secs,
        fps,
        speed,
    })
}

pub fn get_video_duration(bins: Option<&ResolvedBinaries>, file: &Path) -> f64 {
    if let Some(b) = bins {
        if let Some(ffprobe) = &b.ffprobe {
            let mut cmd = StdCommand::new(ffprobe);
            cmd.args([
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
            ])
            .arg(file)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
            apply_no_window_std(&mut cmd);

            if let Ok(out) = cmd.output() {
                if out.status.success() {
                    if let Ok(sec) = String::from_utf8_lossy(&out.stdout).trim().parse::<f64>() {
                        if sec > 0.0 {
                            return sec;
                        }
                    }
                }
            }
        }

        let mut cmd = StdCommand::new(&b.ffmpeg);
        cmd.arg("-i")
            .arg(file)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        apply_no_window_std(&mut cmd);

        if let Ok(out) = cmd.output() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            if let Some(sec) = parse_duration_str(&stderr) {
                if sec > 0.0 {
                    return sec;
                }
            }
        }
    }

    0.0
}

pub fn scan_inputs(paths: Vec<String>) -> Vec<VideoItemInfo> {
    let bins = find_binaries();
    let mut seen: HashSet<String> = HashSet::new();
    let mut collected_files: Vec<PathBuf> = Vec::new();

    for raw in paths {
        let trimmed = raw.trim().trim_matches('"');
        if trimmed.is_empty() {
            continue;
        }
        let p = PathBuf::from(trimmed);
        if p.is_dir() {
            if let Ok(entries) = fs::read_dir(&p) {
                let mut dir_files: Vec<PathBuf> = entries
                    .filter_map(|e| e.ok())
                    .map(|e| e.path())
                    .filter(|f| f.is_file() && is_supported_video(f))
                    .collect();
                dir_files.sort_by(|a, b| {
                    a.file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .to_ascii_lowercase()
                        .cmp(
                            &b.file_name()
                                .unwrap_or_default()
                                .to_string_lossy()
                                .to_ascii_lowercase(),
                        )
                });
                for f in dir_files {
                    let key = fs::canonicalize(&f)
                        .unwrap_or_else(|_| f.clone())
                        .to_string_lossy()
                        .to_ascii_lowercase();
                    if seen.insert(key) {
                        collected_files.push(f);
                    }
                }
            }
        } else if p.is_file() && is_supported_video(&p) {
            let key = fs::canonicalize(&p)
                .unwrap_or_else(|_| p.clone())
                .to_string_lossy()
                .to_ascii_lowercase();
            if seen.insert(key) {
                collected_files.push(p);
            }
        }
    }

    collected_files
        .into_iter()
        .filter_map(|file| {
            let meta = fs::metadata(&file).ok()?;
            let file_name = file
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| file.to_string_lossy().to_string());
            let duration_secs = get_video_duration(bins.as_ref(), &file);
            Some(VideoItemInfo {
                path: file.to_string_lossy().to_string(),
                file_name,
                size_bytes: meta.len(),
                duration_secs,
            })
        })
        .collect()
}

pub fn resolve_preset(preset: &str, resolusi: &str) -> PresetSpec {
    let clean_res = resolusi.trim();
    match preset.trim().to_ascii_lowercase().as_str() {
        "ringan" => PresetSpec {
            codec: "libx264",
            crf: 20,
            ffmpeg_preset: "medium",
            audio_bitrate: "160k",
            effective_resolusi: clean_res.to_string(),
        },
        "youtube" => PresetSpec {
            codec: "libx264",
            crf: 18,
            ffmpeg_preset: "slow",
            audio_bitrate: "192k",
            effective_resolusi: clean_res.to_string(),
        },
        "kecil" => PresetSpec {
            codec: "libx264",
            crf: 28,
            ffmpeg_preset: "fast",
            audio_bitrate: "96k",
            effective_resolusi: if clean_res.is_empty() {
                "720".to_string()
            } else {
                clean_res.to_string()
            },
        },
        "265" => PresetSpec {
            codec: "libx265",
            crf: 26,
            ffmpeg_preset: "medium",
            audio_bitrate: "128k",
            effective_resolusi: clean_res.to_string(),
        },
        _ => PresetSpec {
            codec: "libx264",
            crf: 23,
            ffmpeg_preset: "medium",
            audio_bitrate: "128k",
            effective_resolusi: clean_res.to_string(),
        },
    }
}

fn build_output_path(input_file: &Path, output_dir: &str) -> Result<PathBuf, String> {
    let parent = input_file
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let stem = input_file
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("output");

    let out_dir_path = if output_dir.trim().is_empty() {
        parent.join("compressed")
    } else {
        PathBuf::from(output_dir.trim())
    };

    fs::create_dir_all(&out_dir_path).map_err(|e| {
        format!(
            "Failed to create output folder {}: {}",
            out_dir_path.display(),
            e
        )
    })?;

    Ok(out_dir_path.join(format!("{}_compressed.mp4", stem)))
}

fn build_ffmpeg_args(
    input: &Path,
    output: &Path,
    spec: &PresetSpec,
    use_nvenc: bool,
) -> Vec<String> {
    let mut args = vec![
        "-stats".to_string(),
        "-y".to_string(),
        "-hide_banner".to_string(),
        "-loglevel".to_string(),
        "error".to_string(),
        "-i".to_string(),
        input.to_string_lossy().to_string(),
    ];

    if !spec.effective_resolusi.is_empty() {
        args.push("-vf".to_string());
        args.push(format!(
            "scale=-2:{}:force_original_aspect_ratio=decrease",
            spec.effective_resolusi
        ));
    }

    if use_nvenc && spec.codec == "libx264" {
        args.extend([
            "-c:v".to_string(),
            "h264_nvenc".to_string(),
            "-preset".to_string(),
            "p5".to_string(),
            "-tune".to_string(),
            "hq".to_string(),
            "-cq".to_string(),
            spec.crf.to_string(),
            "-b:v".to_string(),
            "0".to_string(),
        ]);
    } else if spec.codec == "libx265" {
        args.extend([
            "-c:v".to_string(),
            "libx265".to_string(),
            "-preset".to_string(),
            spec.ffmpeg_preset.to_string(),
            "-crf".to_string(),
            spec.crf.to_string(),
            "-x265-params".to_string(),
            "log-level=error".to_string(),
            "-tag:v".to_string(),
            "hvc1".to_string(),
        ]);
    } else {
        args.extend([
            "-c:v".to_string(),
            "libx264".to_string(),
            "-preset".to_string(),
            spec.ffmpeg_preset.to_string(),
            "-crf".to_string(),
            spec.crf.to_string(),
        ]);
    }

    args.extend([
        "-c:a".to_string(),
        "aac".to_string(),
        "-b:a".to_string(),
        spec.audio_bitrate.to_string(),
        "-pix_fmt".to_string(),
        "yuv420p".to_string(),
        "-movflags".to_string(),
        "+faststart".to_string(),
        output.to_string_lossy().to_string(),
    ]);
    args
}

enum EncodeOutcome {
    Success,
    Failed(String),
    Cancelled,
}

fn push_error_tail(err_lines: &mut Vec<String>, line: &str) {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with("frame=") {
        return;
    }
    err_lines.push(trimmed.to_string());
    if err_lines.len() > 5 {
        err_lines.remove(0);
    }
}

fn handle_stderr_segment(
    seg: &str,
    app: &AppHandle,
    item: &VideoItemInfo,
    index: usize,
    total: usize,
    last_emit: &mut Instant,
    err_lines: &mut Vec<String>,
) {
    let trimmed = seg.trim();
    if trimmed.is_empty() {
        return;
    }

    if trimmed.starts_with("frame=") {
        if let Some(sample) = parse_stats_line(trimmed) {
            if last_emit.elapsed() >= Duration::from_millis(120) {
                *last_emit = Instant::now();
                let percent = if item.duration_secs > 0.0 {
                    ((sample.elapsed_secs / item.duration_secs) * 100.0).clamp(0.0, 100.0)
                } else {
                    0.0
                };
                let _ = app.emit(
                    "compression-progress",
                    CompressionProgressEvent {
                        path: item.path.clone(),
                        index,
                        total,
                        percent: (percent * 10.0).round() / 10.0,
                        elapsed_secs: sample.elapsed_secs,
                        duration_secs: item.duration_secs,
                        fps: sample.fps,
                        speed: sample.speed,
                    },
                );
            }
        }
    } else {
        push_error_tail(err_lines, trimmed);
    }
}

async fn run_single_encode(
    app: &AppHandle,
    state: &CompressionState,
    ffmpeg_path: &Path,
    args: &[String],
    item: &VideoItemInfo,
    index: usize,
    total: usize,
) -> EncodeOutcome {
    let mut cmd = TokioCommand::new(ffmpeg_path);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    apply_no_window_tokio(&mut cmd);

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return EncodeOutcome::Failed(format!("Failed to launch ffmpeg: {}", e)),
    };

    if let Ok(mut pid) = state.active_pid.lock() {
        *pid = child.id();
    }

    let mut stderr = match child.stderr.take() {
        Some(s) => s,
        None => {
            let _ = child.kill().await;
            return EncodeOutcome::Failed("Unable to read ffmpeg stderr output.".to_string());
        }
    };

    let mut buf = [0u8; 4096];
    let mut pending = String::new();
    let mut err_lines: Vec<String> = Vec::new();
    let mut last_emit = Instant::now() - Duration::from_secs(1);

    loop {
        if state.cancel_flag.load(Ordering::SeqCst) {
            let _ = child.kill().await;
            let _ = child.wait().await;
            return EncodeOutcome::Cancelled;
        }

        let read_res = tokio::time::timeout(Duration::from_millis(150), stderr.read(&mut buf)).await;
        match read_res {
            Ok(Ok(0)) => break,
            Ok(Ok(n)) => {
                pending.push_str(&String::from_utf8_lossy(&buf[..n]));
                while let Some(pos) = pending.find(['\r', '\n']) {
                    let seg = pending[..pos].to_string();
                    pending.drain(..=pos);
                    handle_stderr_segment(
                        &seg,
                        app,
                        item,
                        index,
                        total,
                        &mut last_emit,
                        &mut err_lines,
                    );
                }
            }
            Ok(Err(e)) => {
                push_error_tail(&mut err_lines, &format!("Stderr read error: {}", e));
                break;
            }
            Err(_) => {
                // Timeout tick so cancel_flag is checked responsively even if ffmpeg pauses stderr.
            }
        }
    }

    if !pending.is_empty() {
        handle_stderr_segment(
            &pending,
            app,
            item,
            index,
            total,
            &mut last_emit,
            &mut err_lines,
        );
    }

    let status = match child.wait().await {
        Ok(s) => s,
        Err(e) => return EncodeOutcome::Failed(format!("Failed while waiting for ffmpeg: {}", e)),
    };

    if state.cancel_flag.load(Ordering::SeqCst) {
        return EncodeOutcome::Cancelled;
    }

    if status.success() {
        EncodeOutcome::Success
    } else if err_lines.is_empty() {
        EncodeOutcome::Failed(format!(
            "ffmpeg exited with code {}.",
            status.code().unwrap_or(-1)
        ))
    } else {
        EncodeOutcome::Failed(err_lines.join(" | "))
    }
}

pub fn cancel_active_compression(state: &CompressionState) -> Result<(), String> {
    state.cancel_flag.store(true, Ordering::SeqCst);
    let pid_opt = state
        .active_pid
        .lock()
        .ok()
        .and_then(|guard| *guard);

    if let Some(pid) = pid_opt {
        #[cfg(windows)]
        {
            let mut cmd = StdCommand::new("taskkill");
            cmd.args(["/PID", &pid.to_string(), "/T", "/F"])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            apply_no_window_std(&mut cmd);
            let _ = cmd.status();
        }
    }
    Ok(())
}

pub async fn run_compression_batch(
    app: AppHandle,
    state: Arc<CompressionState>,
    items: Vec<VideoItemInfo>,
    mut app_settings: AppSettings,
) -> Result<(), String> {
    if items.is_empty() {
        return Err("Video queue is empty.".to_string());
    }

    let _guard = RunningGuard::acquire(state.clone())?;
    app_settings = app_settings.sanitize();
    let _ = settings::save_settings(&app_settings);

    let bins = tokio::task::spawn_blocking(find_binaries)
        .await
        .map_err(|e| format!("Failed to check FFmpeg: {}", e))?
        .ok_or_else(|| "FFmpeg not found. Please download FFmpeg first.".to_string())?;

    let spec = resolve_preset(&app_settings.preset, &app_settings.resolusi);
    let mut effective_use_gpu = app_settings.use_gpu;

    if effective_use_gpu && spec.codec == "libx264" {
        let ffmpeg_for_probe = bins.ffmpeg.clone();
        let gpu_ok = tokio::task::spawn_blocking(move || test_nvenc(&ffmpeg_for_probe))
            .await
            .unwrap_or(false);
        if !gpu_ok {
            effective_use_gpu = false;
            app_settings.use_gpu = false;
            let _ = settings::save_settings(&app_settings);
            let _ = app.emit(
                "gpu-fallback",
                GpuFallbackEvent {
                    reason: "GPU NVENC not detected or unavailable, switched to CPU."
                        .to_string(),
                },
            );
        }
    }

    let total_items = items.len();
    let mut succeeded: usize = 0;
    let mut failed: usize = 0;
    let mut cancelled = false;
    let mut total_before_bytes: u64 = 0;
    let mut total_after_bytes: u64 = 0;

    for (index, mut item) in items.into_iter().enumerate() {
        if state.cancel_flag.load(Ordering::SeqCst) {
            cancelled = true;
            let _ = app.emit(
                "compression-item-cancelled",
                CompressionItemCancelledEvent {
                    path: item.path.clone(),
                    index,
                },
            );
            break;
        }

        let input_path = PathBuf::from(&item.path);
        if !input_path.is_file() {
            failed += 1;
            let _ = app.emit(
                "compression-item-error",
                CompressionItemErrorEvent {
                    path: item.path.clone(),
                    index,
                    error: format!("File not found: {}", item.path),
                },
            );
            continue;
        }

        let before_bytes = fs::metadata(&input_path)
            .map(|m| m.len())
            .unwrap_or(item.size_bytes);
        if item.duration_secs <= 0.0 {
            let bins_clone = bins.clone();
            let input_clone = input_path.clone();
            item.duration_secs =
                tokio::task::spawn_blocking(move || get_video_duration(Some(&bins_clone), &input_clone))
                    .await
                    .unwrap_or(0.0);
        }

        let out_path = match build_output_path(&input_path, &app_settings.output_dir) {
            Ok(p) => p,
            Err(err) => {
                failed += 1;
                let _ = app.emit(
                    "compression-item-error",
                    CompressionItemErrorEvent {
                        path: item.path.clone(),
                        index,
                        error: err,
                    },
                );
                continue;
            }
        };

        let mut used_gpu_for_item = effective_use_gpu && spec.codec == "libx264";
        let args = build_ffmpeg_args(&input_path, &out_path, &spec, used_gpu_for_item);
        let mut outcome = run_single_encode(
            &app,
            &state,
            &bins.ffmpeg,
            &args,
            &item,
            index,
            total_items,
        )
        .await;

        if matches!(outcome, EncodeOutcome::Failed(_)) && used_gpu_for_item {
            let _ = fs::remove_file(&out_path);
            effective_use_gpu = false;
            used_gpu_for_item = false;
            app_settings.use_gpu = false;
            let _ = settings::save_settings(&app_settings);
            let _ = app.emit(
                "gpu-fallback",
                GpuFallbackEvent {
                    reason: "GPU encoding failed mid-run, retrying automatically on CPU.".to_string(),
                },
            );

            let cpu_args = build_ffmpeg_args(&input_path, &out_path, &spec, false);
            outcome = run_single_encode(
                &app,
                &state,
                &bins.ffmpeg,
                &cpu_args,
                &item,
                index,
                total_items,
            )
            .await;
        }

        if let Ok(mut pid) = state.active_pid.lock() {
            *pid = None;
        }

        match outcome {
            EncodeOutcome::Cancelled => {
                let _ = fs::remove_file(&out_path);
                cancelled = true;
                let _ = app.emit(
                    "compression-item-cancelled",
                    CompressionItemCancelledEvent {
                        path: item.path.clone(),
                        index,
                    },
                );
                break;
            }
            EncodeOutcome::Failed(err) => {
                let _ = fs::remove_file(&out_path);
                failed += 1;
                let _ = app.emit(
                    "compression-item-error",
                    CompressionItemErrorEvent {
                        path: item.path.clone(),
                        index,
                        error: err,
                    },
                );
            }
            EncodeOutcome::Success => {
                let after_bytes = fs::metadata(&out_path).map(|m| m.len()).unwrap_or(0);
                if after_bytes == 0 {
                    let _ = fs::remove_file(&out_path);
                    failed += 1;
                    let _ = app.emit(
                        "compression-item-error",
                        CompressionItemErrorEvent {
                            path: item.path.clone(),
                            index,
                            error: "Output file is empty or was not created.".to_string(),
                        },
                    );
                    continue;
                }

                let saved_percent = if before_bytes > 0 {
                    ((1.0 - (after_bytes as f64 / before_bytes as f64)) * 1000.0).round() / 10.0
                } else {
                    0.0
                };

                succeeded += 1;
                total_before_bytes += before_bytes;
                total_after_bytes += after_bytes;

                let _ = app.emit(
                    "compression-progress",
                    CompressionProgressEvent {
                        path: item.path.clone(),
                        index,
                        total: total_items,
                        percent: 100.0,
                        elapsed_secs: item.duration_secs,
                        duration_secs: item.duration_secs,
                        fps: None,
                        speed: None,
                    },
                );

                let _ = app.emit(
                    "compression-item-done",
                    CompressionItemDoneEvent {
                        path: item.path.clone(),
                        index,
                        output_path: out_path.to_string_lossy().to_string(),
                        before_bytes,
                        after_bytes,
                        saved_percent,
                        used_gpu: used_gpu_for_item,
                    },
                );
            }
        }
    }

    let _ = app.emit(
        "compression-finished",
        CompressionFinishedEvent {
            cancelled,
            total_items,
            succeeded,
            failed,
            total_before_bytes,
            total_after_bytes,
        },
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_preset_matches_powershell_script() {
        let ringan = resolve_preset("ringan", "");
        assert_eq!(ringan.codec, "libx264");
        assert_eq!(ringan.crf, 20);
        assert_eq!(ringan.ffmpeg_preset, "medium");
        assert_eq!(ringan.audio_bitrate, "160k");
        assert_eq!(ringan.effective_resolusi, "");

        let kecil_auto = resolve_preset("kecil", "");
        assert_eq!(kecil_auto.codec, "libx264");
        assert_eq!(kecil_auto.crf, 28);
        assert_eq!(kecil_auto.ffmpeg_preset, "fast");
        assert_eq!(kecil_auto.audio_bitrate, "96k");
        assert_eq!(kecil_auto.effective_resolusi, "720");

        let kecil_override = resolve_preset("kecil", "480");
        assert_eq!(kecil_override.effective_resolusi, "480");

        let h265 = resolve_preset("265", "1080");
        assert_eq!(h265.codec, "libx265");
        assert_eq!(h265.crf, 26);
        assert_eq!(h265.ffmpeg_preset, "medium");
        assert_eq!(h265.audio_bitrate, "128k");
        assert_eq!(h265.effective_resolusi, "1080");
    }

    #[test]
    fn parse_stats_line_extracts_time_fps_speed() {
        let line = "frame=  420 fps= 68.5 q=25.0 size=    2048kB time=00:01:23.45 bitrate= 201.1kbits/s speed=2.74x";
        let sample = parse_stats_line(line).unwrap();
        assert!((sample.elapsed_secs - 83.45).abs() < 0.001);
        assert_eq!(sample.fps, Some(68.5));
        assert_eq!(sample.speed, Some(2.74));
    }

    #[test]
    fn parse_duration_str_extracts_seconds() {
        let info = "  Duration: 01:02:03.50, start: 0.000000, bitrate: 2450 kb/s";
        let secs = parse_duration_str(info).unwrap();
        assert!((secs - 3723.5).abs() < 0.001);
    }

    #[test]
    fn build_args_for_265_and_nvenc() {
        let spec_265 = resolve_preset("265", "720");
        let args_265 = build_ffmpeg_args(
            Path::new("in.mp4"),
            Path::new("out.mp4"),
            &spec_265,
            true,
        );
        assert!(args_265.contains(&"libx265".to_string()));
        assert!(args_265.contains(&"hvc1".to_string()));
        assert!(args_265.contains(&"scale=-2:720:force_original_aspect_ratio=decrease".to_string()));

        let spec_std = resolve_preset("seimbang", "");
        let args_nvenc = build_ffmpeg_args(
            Path::new("in.mp4"),
            Path::new("out.mp4"),
            &spec_std,
            true,
        );
        assert!(args_nvenc.contains(&"h264_nvenc".to_string()));
        assert!(args_nvenc.contains(&"-cq".to_string()));
        assert!(args_nvenc.contains(&"23".to_string()));
    }
}
