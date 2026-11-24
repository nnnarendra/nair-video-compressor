@echo off
REM Usage:
REM   - Double-click this file (no video) -> opens the settings menu first.
REM     [0] GPU on/off, [1] preset, [2] resolution, [3] video path, [4] output, [5] start.
REM   - Drag & drop a video onto this file -> compresses IMMEDIATELY using the last saved settings, skipping the menu.
REM Last used settings are saved automatically in kompres-video-settings.json.
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kompres-video.ps1" -Menu
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kompres-video.ps1" -Path "%~1"
)
pause
