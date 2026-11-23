@echo off
REM Klik saja:
REM   - Double-click file ini (tanpa video) -> menu muncul duluan.
REM     [0] GPU on/off, [1] preset, [2] resolusi, [3] path video, [4] output, [5] mulai.
REM   - Drag & drop video ke file ini -> LANGSUNG kompres pakai setting terakhir, tanpa menu.
REM Setting terakhir tersimpan otomatis di kompres-video-settings.json.
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kompres-video.ps1" -Menu
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kompres-video.ps1" -Path "%~1"
)
pause
