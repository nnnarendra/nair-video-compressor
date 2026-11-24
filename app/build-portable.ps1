$ErrorActionPreference = "Stop"

$AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $AppDir
$SrcTauriDir = Join-Path $AppDir "src-tauri"
$LauncherDir = Join-Path $AppDir "launcher"
$DistRoot = Join-Path $RepoRoot "dist"
$DistPortableDir = Join-Path $DistRoot "nair-video-compressor-portable"
$SingleExePath = Join-Path $DistRoot "Nair-Video-Compressor.exe"

if (-not (Get-Command dlltool.exe -ErrorAction SilentlyContinue)) {
    $mingwBin = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\BrechtSanders.WinLibs.POSIX.MSVCRT*" -Recurse -Directory -Filter bin -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "dlltool.exe") } |
        Select-Object -First 1 -ExpandProperty FullName
    if ($mingwBin) {
        $env:PATH = "$mingwBin;$env:PATH"
        Write-Host "Using MinGW toolchain: $mingwBin"
    }
}

Write-Host "Building main Tauri release binary..."
Push-Location $SrcTauriDir
try {
    cargo build --release
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build --release (app) failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

$ReleaseExe = Join-Path $SrcTauriDir "target\release\nair-video-compressor.exe"
if (-not (Test-Path $ReleaseExe)) {
    throw "Release executable not found at $ReleaseExe"
}

$WebView2Dll = Join-Path $SrcTauriDir "target\release\WebView2Loader.dll"
if (-not (Test-Path $WebView2Dll)) {
    $WebView2Dll = Get-ChildItem (Join-Path $SrcTauriDir "target\release\build\webview2-com-sys") -Recurse -Filter "WebView2Loader.dll" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $WebView2Dll -or -not (Test-Path $WebView2Dll)) {
    throw "WebView2Loader.dll not found under target\release"
}

New-Item -ItemType Directory -Force -Path $DistPortableDir | Out-Null
$StagedExe = Join-Path $DistPortableDir "nair-video-compressor.exe"
$StagedDll = Join-Path $DistPortableDir "WebView2Loader.dll"
Copy-Item -Force $ReleaseExe $StagedExe
Copy-Item -Force $WebView2Dll $StagedDll

Write-Host "Building single-file portable launcher..."
$exeLen = (Get-Item $StagedExe).Length
$dllLen = (Get-Item $StagedDll).Length
$env:NAIR_APP_EXE = $StagedExe
$env:NAIR_WV2_DLL = $StagedDll
$env:NAIR_BUILD_STAMP = "0.1.0-$exeLen-$dllLen"

Push-Location $LauncherDir
try {
    cargo build --release
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build --release (launcher) failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}

$LauncherExe = Join-Path $LauncherDir "target\release\nair-video-compressor-launcher.exe"
if (-not (Test-Path $LauncherExe)) {
    throw "Launcher executable not found at $LauncherExe"
}
Copy-Item -Force $LauncherExe $SingleExePath

$singleInfo = Get-Item $SingleExePath
Write-Host ""
Write-Host "Single-file portable EXE ready: $SingleExePath"
Write-Host ("  Nair-Video-Compressor.exe : {0:N2} MB ({1:N0} bytes)" -f ($singleInfo.Length / 1MB), $singleInfo.Length)
Write-Host "Folder bundle also updated  : $DistPortableDir"
