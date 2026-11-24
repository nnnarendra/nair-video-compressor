# Nair Video Compressor

A lightweight, portable Windows video compressor powered by **FFmpeg**, built with **Tauri v2** alongside the original interactive PowerShell/Batch CLI scripts.

---

## Features

- **Drag & Drop Queue:** Drop individual video files (`.mp4`, `.mov`, `.mkv`, `.avi`, `.webm`) or entire folders for batch compression.
- **5 Compression Presets:**

| Preset Key | UI Label | Video Codec | CRF / CQ | FFmpeg Preset | Audio | Notes |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `ringan` | Light | `libx264` | `20` | `medium` | `160k` | High quality |
| `seimbang` | Balanced | `libx264` | `23` | `medium` | `128k` | Recommended default |
| `youtube` | YouTube | `libx264` | `18` | `slow` | `192k` | Upload quality |
| `kecil` | Compact | `libx264` | `28` | `fast` | `96k` | Auto-scales to `720p` when set to Original |
| `265` | H.265 | `libx265` | `26` | `medium` | `128k` | Smallest file size (`-tag:v hvc1`) |

- **Resolution Scaling:** `Original`, `1080p`, `720p`, or `480p` (preserves aspect ratio).
- **GPU Acceleration (NVENC) + Safe CPU Fallback:** Automatically tests `h264_nvenc` and falls back to `libx264` CPU if NVENC is unavailable or fails mid-encode.
- **Hybrid FFmpeg Detection & In-App Downloader:**
  1. Checks `bin/ffmpeg.exe` or `ffmpeg.exe` next to the portable executable.
  2. Checks `%LOCALAPPDATA%\nair-video-compressor\bin\ffmpeg.exe`.
  3. Checks system `PATH`.
  4. If missing, offers a one-click **Download FFmpeg (~80 MB)** button inside the app to fetch and extract the official `ffmpeg-release-essentials.zip` from `gyan.dev`.
- **Single-File Portable Build:** Packages the Tauri app and `WebView2Loader.dll` into a single ~6.3 MB `Nair-Video-Compressor.exe` launcher that preserves portable settings (`kompres-video-settings.json`) and local `bin/` next to the `.exe`.
- **Real-Time Progress & Cancellation:** Streams elapsed time, percentage, FPS, encode speed, and file-size savings, with instant cancel support.

---

## Usage

### 1. Portable Desktop App
1. Build or download `Nair-Video-Compressor.exe`.
2. Double-click `Nair-Video-Compressor.exe` (Windows 10/11 with Microsoft Edge WebView2 Runtime).
3. Drag and drop video files or folders into the window, choose your preset/resolution/acceleration, and click **START COMPRESSION**.
4. Compressed files are saved to a `compressed/` subfolder next to each source file (or to your custom output folder).

### 2. PowerShell / Batch Scripts
- **Interactive menu:** Double-click `kompres-video.bat` (or run `.\kompres-video.ps1 -Menu`).
- **Instant drag & drop:** Drag a video file onto `kompres-video.bat` to compress immediately with the last saved settings.
- **Non-interactive CLI:**
  ```powershell
  .\kompres-video.ps1 -NoMenu -Preset seimbang -Resolusi 720 "D:\video.mp4"
  ```

Settings are shared between the desktop app and the scripts via `kompres-video-settings.json`.

---

## Building from Source (Windows)

### Prerequisites
- [Rust](https://rustup.rs/) (`stable-x86_64-pc-windows-gnu`)
- MinGW-w64 (`BrechtSanders.WinLibs.POSIX.MSVCRT` via `winget`, auto-detected by `app/build-portable.ps1`)
- Microsoft Edge WebView2 Runtime (pre-installed on Windows 10/11)

### Build Commands
```powershell
# Run backend unit tests
Push-Location app\src-tauri
cargo test
Pop-Location

# Build both the single-file portable EXE and folder bundle into dist/
powershell -NoProfile -ExecutionPolicy Bypass -File app\build-portable.ps1
```

Outputs are generated in `dist/`:
- `dist/Nair-Video-Compressor.exe` — Single-file portable launcher
- `dist/nair-video-compressor-portable/` — Folder bundle (`nair-video-compressor.exe` + `WebView2Loader.dll`)

---

## Project Structure

```text
nair-video-compressor/
├── README.md
├── kompres-video.bat              # Windows Batch wrapper for the CLI script
├── kompres-video.ps1              # Interactive PowerShell compressor script
├── kompres-video-settings.json    # Persisted settings shared by GUI & CLI
└── app/
    ├── build-portable.ps1         # Release & single-file portable build script
    ├── src/                       # Minimalism & Swiss Style frontend (HTML/CSS/JS)
    ├── src-tauri/                 # Tauri v2 Rust backend (FFmpeg, settings, IPC)
    └── launcher/                  # Single-file portable wrapper crate
```
