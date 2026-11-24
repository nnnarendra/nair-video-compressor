<#
Video compressor using ffmpeg - Windows PowerShell interactive version
======================================================================
THREE WAYS TO USE:
  1. Double-click kompres-video.bat (no file) -> opens the menu first.
     Type a number and press Enter:
       [0] Toggle GPU on/off
       [1] Change preset (quality / file size)
       [2] Change resolution
       [3] Enter / change video path
       [4] Change output folder
       [5] Start compression (or just press Enter)
       [9] Exit
  2. Drag & drop a video file onto kompres-video.bat, or run:
     .\kompres-video.ps1 "D:\video.mp4"
     -> Compresses IMMEDIATELY using the last saved settings, without the menu.
     Want to change settings first? Run with -Menu.
  3. Fully non-interactive (automation):
     .\kompres-video.ps1 -NoMenu video.mp4

SAVED SETTINGS:
  Every time compression finishes (or you exit the menu), the last used
  settings are saved to kompres-video-settings.json next to this script.
  Re-open it later and your settings will still be there.

GPU:
  If GPU is enabled but NVENC is not detected or fails during encoding,
  the script automatically falls back to CPU and notifies you.
#>
[CmdletBinding()]
param(
  [ValidateSet("ringan","seimbang","youtube","kecil","265")]
  [string]$Preset = "seimbang",
  [ValidateSet("","1080","720","480")]
  [string]$Resolusi = "",
  [string]$OutputDir = "",
  [switch]$Gpu,
  [switch]$Menu,
  [switch]$NoMenu,
  [Parameter(Position=0, ValueFromRemainingArguments=$true)]
  [string[]]$Path
)

# --- Saved settings (JSON next to script) ---
$script:SettingsPath = ""
$script:UseGpu = $false
$script:GpuTested = $false
$script:GpuAvailable = $false
$script:GpuFallback = $false

function Clean-Path([string]$p) { return $p.Trim().Trim('"') }

function Load-Settings {
  if ($PSScriptRoot) { $script:SettingsPath = Join-Path $PSScriptRoot "kompres-video-settings.json" }
  elseif ($PSCommandPath) { $script:SettingsPath = Join-Path (Split-Path $PSCommandPath -Parent) "kompres-video-settings.json" }
  else { $script:SettingsPath = Join-Path (Get-Location) "kompres-video-settings.json" }
  if (-not (Test-Path $script:SettingsPath)) { return $false }
  try {
    $s = Get-Content $script:SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($s.Preset -and @("ringan","seimbang","youtube","kecil","265") -contains $s.Preset) { $script:Preset = $s.Preset }
    if ($null -ne $s.Resolusi -and @("","1080","720","480") -contains $s.Resolusi) { $script:Resolusi = $s.Resolusi }
    if ($null -ne $s.OutputDir) { $script:OutputDir = [string]$s.OutputDir }
    if ($null -ne $s.UseGpu) { $script:UseGpu = [bool]$s.UseGpu }
    return $true
  } catch {
    return $false
  }
}

function Save-Settings {
  if (-not $script:SettingsPath) { return }
  try {
    $obj = [ordered]@{ Preset = $script:Preset; Resolusi = $script:Resolusi; OutputDir = $script:OutputDir; UseGpu = $script:UseGpu }
    $obj | ConvertTo-Json | Set-Content $script:SettingsPath -Encoding UTF8 -ErrorAction Stop
  } catch {
    # Saving failure is non-fatal - compression continues.
  }
}

function Test-GpuAvailable {
  if ($script:GpuTested) { return $script:GpuAvailable }
  $script:GpuTested = $true
  $script:GpuAvailable = $false
  $tmp = Join-Path $env:TEMP "gpu-test-nvenc.mp4"
  try { Remove-Item $tmp -ErrorAction SilentlyContinue } catch { }
  # Run a 0.1s NVENC encode test. If drivers are incompatible or no NVIDIA
  # GPU is present, this command exits with a non-zero status.
  & ffmpeg -y -hide_banner -loglevel error -f lavfi -i "color=c=black:s=128x128:d=0.1" -c:v h264_nvenc -preset p1 -f mp4 $tmp 2>$null
  $code = $LASTEXITCODE
  if (($code -eq 0) -and (Test-Path $tmp)) { $script:GpuAvailable = $true }
  try { Remove-Item $tmp -ErrorAction SilentlyContinue } catch { }
  return $script:GpuAvailable
}

function Get-PresetLabel([string]$p) {
  switch ($p) {
    "ringan"   { return "ringan (Light - H.264, CRF 20 - high quality)" }
    "seimbang" { return "seimbang (Balanced - H.264, CRF 23 - recommended)" }
    "youtube"  { return "youtube (YouTube - H.264, CRF 18 - upload quality)" }
    "kecil"    { return "kecil (Compact - H.264, CRF 28 + 720p - smallest size)" }
    "265"      { return "265 (H.265, CRF 26 - smallest file, slower encode)" }
  }
  return $p
}

function Update-Settings {
  switch ($Preset) {
    "ringan"   { $script:Codec="libx264"; $script:Crf=20; $script:FP="medium"; $script:AB="160k" }
    "seimbang" { $script:Codec="libx264"; $script:Crf=23; $script:FP="medium"; $script:AB="128k" }
    "youtube"  { $script:Codec="libx264"; $script:Crf=18; $script:FP="slow";   $script:AB="192k" }
    "kecil"    { $script:Codec="libx264"; $script:Crf=28; $script:FP="fast";   $script:AB="96k" }
    "265"      { $script:Codec="libx265"; $script:Crf=26; $script:FP="medium"; $script:AB="128k" }
  }
  # Compact preset automatically scales down to 720p unless resolution is set manually.
  $script:EffectiveResolusi = $Resolusi
  if ($Preset -eq "kecil" -and -not $script:EffectiveResolusi) { $script:EffectiveResolusi = "720" }
}

function Show-Status {
  Write-Host ""
  Write-Host "==============================" -ForegroundColor Cyan
  Write-Host "  VIDEO COMPRESSOR" -ForegroundColor Cyan
  Write-Host "==============================" -ForegroundColor Cyan
  if (-not $Path -or $Path.Count -eq 0) {
    Write-Host "  File      : (none yet - choose [3] to enter a video path)" -ForegroundColor Yellow
  }
  foreach ($t in $Path) {
    $clean = Clean-Path $t
    if (Test-Path $clean -PathType Container) {
      $n = (Get-ChildItem $clean -Include *.mp4,*.mov,*.mkv,*.avi,*.webm -File -ErrorAction SilentlyContinue).Count
      Write-Host "  File      : $clean  ($n videos in folder)"
    } elseif (Test-Path $clean) {
      $mb = [math]::Round((Get-Item $clean).Length / 1MB, 1)
      Write-Host "  File      : $clean  ($mb MB)"
    } else {
      Write-Host "  File      : $clean  (not found!)" -ForegroundColor Red
    }
  }
  Write-Host "  Preset    : $(Get-PresetLabel $Preset)"
  if ($Resolusi) { Write-Host "  Resolution: ${Resolusi}p" }
  elseif ($Preset -eq "kecil") { Write-Host "  Resolution: original -> 720p (auto compact preset)" }
  else { Write-Host "  Resolution: original (unchanged)" }
  if ($script:GpuFallback) {
    Write-Host "  GPU       : OFF (fallback - NVENC not detected, using CPU)" -ForegroundColor Yellow
  } elseif ($script:UseGpu) {
    Write-Host "  GPU       : ON  (NVENC, fast)"
  } else {
    Write-Host "  GPU       : OFF (CPU, stable)"
  }
  $outText = if ($OutputDir) { $OutputDir } else { "compressed/ folder next to source file" }
  Write-Host "  Output    : $outText"
  Write-Host "  Settings  : auto-saved, preserved on next launch"
  Write-Host ""
}

function Choose-Preset {
  Write-Host ""
  Write-Host "Select preset:"
  Write-Host "  [1] ringan   - Light (CRF 20, high quality, larger file)"
  Write-Host "  [2] seimbang - Balanced (CRF 23, quality/size sweet spot, default)"
  Write-Host "  [3] youtube  - YouTube (CRF 18, upload quality)"
  Write-Host "  [4] kecil    - Compact (CRF 28 + 720p, smallest possible size)"
  Write-Host "  [5] 265      - H.265 (CRF 26, smallest file, slower encode)"
  Write-Host "  [9] back"
  $c = (Read-Host "Choose preset [2]").Trim()
  if ($c -eq "") { $c = "2" }
  switch ($c) {
    "1" { $script:Preset = "ringan" }
    "2" { $script:Preset = "seimbang" }
    "3" { $script:Preset = "youtube" }
    "4" { $script:Preset = "kecil" }
    "5" { $script:Preset = "265" }
    "9" { }
    default { Write-Host "Unknown option, preset unchanged." -ForegroundColor Yellow }
  }
}

function Choose-Resolusi {
  Write-Host ""
  Write-Host "Select resolution:"
  Write-Host "  [1] Original (unchanged)"
  Write-Host "  [2] 1080p"
  Write-Host "  [3] 720p"
  Write-Host "  [4] 480p"
  Write-Host "  [9] back"
  $c = (Read-Host "Choose resolution [1]").Trim()
  if ($c -eq "") { $c = "1" }
  switch ($c) {
    "1" { $script:Resolusi = "" }
    "2" { $script:Resolusi = "1080" }
    "3" { $script:Resolusi = "720" }
    "4" { $script:Resolusi = "480" }
    "9" { }
    default { Write-Host "Unknown option, resolution unchanged." -ForegroundColor Yellow }
  }
}

function Ask-Path {
  Write-Host ""
  Write-Host "Enter video file or folder path."
  Write-Host "Tip: drag the video file into this window, then press Enter. Quotes are optional."
  $p = Read-Host "Video file path"
  if (-not $p -or -not $p.Trim()) { return $false }
  $script:Path = @(Clean-Path $p)
  return $true
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  Write-Host "ffmpeg was not found in PATH. Install it first: winget install Gyan.FFmpeg" -ForegroundColor Red; exit 1
}

# --- Load last settings, then explicit CLI parameters override ---
$explicitPreset = $null; if ($PSBoundParameters.ContainsKey('Preset')) { $explicitPreset = $Preset }
$explicitResolusi = $null; if ($PSBoundParameters.ContainsKey('Resolusi')) { $explicitResolusi = $Resolusi }
$explicitOutputDir = $null; if ($PSBoundParameters.ContainsKey('OutputDir')) { $explicitOutputDir = $OutputDir }
$explicitGpu = $null; if ($PSBoundParameters.ContainsKey('Gpu')) { $explicitGpu = [bool]$Gpu }
Load-Settings | Out-Null
if ($null -ne $explicitPreset) { $script:Preset = $explicitPreset }
if ($null -ne $explicitResolusi) { $script:Resolusi = $explicitResolusi }
if ($null -ne $explicitOutputDir) { $script:OutputDir = $explicitOutputDir }
if ($null -ne $explicitGpu) { $script:UseGpu = $explicitGpu }

# Strip quotes from paths passed via drag & drop or paste.
if ($Path -and $Path.Count -gt 0) { $script:Path = @($Path | ForEach-Object { Clean-Path $_ }) }

# --- Menu visibility logic ---
# -Menu           -> show menu (even if path was provided)
# -NoMenu         -> compress immediately without menu
# No path         -> show menu (no input file yet)
# Path provided   -> compress IMMEDIATELY with last saved settings, no menu
$showMenu = $false
if ($NoMenu) { $showMenu = $false }
elseif ($Menu) { $showMenu = $true }
elseif (-not $Path -or $Path.Count -eq 0) { $showMenu = $true }
else { $showMenu = $false }

# --- Interactive menu ---
if ($showMenu) {
  $startCompress = $false
  while (-not $startCompress) {
    Update-Settings
    Show-Status
    Write-Host "  [0] GPU on/off (currently: $(if ($script:UseGpu) { 'ON' } else { 'OFF' }))"
    Write-Host "  [1] Change preset (quality / file size)"
    Write-Host "  [2] Change resolution"
    Write-Host "  [3] Enter / change video path"
    Write-Host "  [4] Change output folder"
    Write-Host "  [5] Start compression (using settings above)"
    Write-Host "  [9] Exit"
    $choice = (Read-Host "Choose [5]").Trim()
    if ($choice -eq "") { $choice = "5" }
    # Strip quotes first: dragging a file into PowerShell pastes a quoted
    # path ("D:\...mp4"), which would fail the path check below.
    $choice = Clean-Path $choice
    # If the user entered a video path directly, use it and start compressing immediately.
    if ($choice -match '^[A-Za-z]:\\' -or $choice -match '\.(mp4|mov|mkv|avi|webm)$') {
      $script:Path = @(Clean-Path $choice)
      $startCompress = $true
      continue
    }
    if ($choice -eq "5") {
      if (-not $Path -or $Path.Count -eq 0) {
        Write-Host "No video file selected yet. Enter its path first." -ForegroundColor Yellow
        if (Ask-Path) { $startCompress = $true }
      } else {
        $startCompress = $true
      }
    } elseif ($choice -eq "0") {
      if (-not $script:UseGpu) {
        Write-Host "Checking GPU (NVENC)..."
        if (Test-GpuAvailable) {
          $script:UseGpu = $true
          $script:GpuFallback = $false
          Write-Host "GPU detected, NVENC enabled."
        } else {
          Write-Host "GPU not detected / NVENC failed, staying on CPU." -ForegroundColor Yellow
        }
      } else {
        $script:UseGpu = $false
        Write-Host "GPU disabled, using CPU."
      }
    } elseif ($choice -eq "1") {
      Choose-Preset
    } elseif ($choice -eq "2") {
      Choose-Resolusi
    } elseif ($choice -eq "3") {
      if (Ask-Path) { $startCompress = $true }
    } elseif ($choice -eq "4") {
      $o = Read-Host "Output folder (empty = default compressed/ folder)"
      $script:OutputDir = $o.Trim().Trim('"')
    } elseif ($choice -eq "9") {
      Save-Settings
      Write-Host "Settings saved. Cancelled."; exit 0
    } else {
      Write-Host "Unknown option, try 0-5 or 9." -ForegroundColor Yellow
    }
  }
}

Update-Settings

# --- GPU enabled but unavailable -> auto-fallback to CPU ---
if ($script:UseGpu) {
  if (-not (Test-GpuAvailable)) {
    Write-Host ""
    Write-Host "GPU not detected / NVENC unavailable, automatically falling back to CPU." -ForegroundColor Yellow
    $script:UseGpu = $false
    $script:GpuFallback = $true
  }
}

# Save last settings before compressing so they persist on next launch.
Save-Settings

if (-not $Path -or $Path.Count -eq 0) {
  Write-Host "No video file provided. Run again and pass a video path." -ForegroundColor Red; exit 1
}

function Get-VideoDuration([string]$file) {
  # Try ffprobe first (most accurate).
  try {
    $raw = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $file 2>$null
    $sec = 0.0
    if ($raw -and [double]::TryParse($raw.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$sec) -and $sec -gt 0) { return $sec }
  } catch { }
  # Fallback: parse "Duration: 00:14:00.00" from ffmpeg -i.
  try {
    $info = & ffmpeg -i $file 2>&1 | Out-String
    if ($info -match 'Duration: (\d+):(\d+):(\d+)\.(\d+)') {
      return ([int]$Matches[1] * 3600) + ([int]$Matches[2] * 60) + [int]$Matches[3] + ([int]$Matches[4] / 100)
    }
  } catch { }
  return 0
}

function Invoke-FfmpegWithProgress([string]$InputFile, [string[]]$FfmpegArgs, [string]$Activity) {
  $duration = Get-VideoDuration $InputFile
  $fmt = if ($duration -ge 3600) { "hh\:mm\:ss" } else { "mm\:ss" }
  $total = if ($duration -gt 0) { [timespan]::FromSeconds($duration).ToString($fmt) } else { "?" }
  $statsFile = Join-Path $env:TEMP ("ffmpeg-stats-" + [guid]::NewGuid().ToString() + ".txt")
  $outFile = Join-Path $env:TEMP ("ffmpeg-out-" + [guid]::NewGuid().ToString() + ".txt")
  $allArgs = @("-stats") + $FfmpegArgs
  $argString = ($allArgs | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  $proc = $null
  try {
    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $argString -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $statsFile -ErrorAction Stop
  } catch {
    Write-Host "  Failed to launch ffmpeg: $($_.Exception.Message)" -ForegroundColor Red
    return -1
  }
  $consumed = 0
  $lastPct = -1
  $lastStats = ""
  $readFails = 0
  while (-not $proc.HasExited) {
    Start-Sleep -Milliseconds 250
    try {
      if (Test-Path $statsFile) {
        # Use Get-Content (FileShare.ReadWrite) because ffmpeg keeps the stats file open for writing.
        $full = Get-Content $statsFile -Raw -ErrorAction Stop
        if ($null -eq $full) { $full = "" }
        if ($full.Length -lt $consumed) { $consumed = 0 }
        if ($full.Length -gt $consumed) {
          $newText = $full.Substring($consumed)
          $consumed = $full.Length
          $segments = $newText -split "[`r`n]+"
          foreach ($seg in $segments) {
            $seg = $seg.Trim()
            if ($seg -eq "") { continue }
            if ($seg.StartsWith("frame=")) {
              $lastStats = $seg
            } else {
              Write-Host $seg
            }
          }
          if ($lastStats -ne "") {
            $w = 100
            try { $w = [Console]::WindowWidth - 1; if ($w -lt 40) { $w = 80 } } catch { $w = 100 }
            $disp = $lastStats
            if ($disp.Length -gt $w) { $disp = $disp.Substring(0, $w) }
            Write-Host -NoNewline ("`r" + $disp.PadRight($w))
            if ($lastStats -match 'time=(\d+):(\d+):(\d+)\.(\d+)') {
              $elapsed = ([int]$Matches[1] * 3600) + ([int]$Matches[2] * 60) + [int]$Matches[3] + ([int]$Matches[4] / 100)
              if ($duration -gt 0) {
                $pct = [math]::Min(100, [math]::Floor($elapsed / $duration * 100.0))
                if ($pct -ne $lastPct) {
                  $lastPct = $pct
                  $done = [timespan]::FromSeconds($elapsed).ToString($fmt)
                  $extra = ""
                  if ($lastStats -match 'fps=\s*([\d\.]+)') { $extra += " fps=" + $Matches[1] }
                  if ($lastStats -match 'speed=\s*([\d\.]+)x') { $extra += " speed=" + $Matches[1] + "x" }
                  Write-Progress -Activity $Activity -Status ("{0}% - {1} / {2}{3}" -f $pct, $done, $total, $extra) -PercentComplete $pct
                }
              } else {
                $done = [timespan]::FromSeconds($elapsed).ToString($fmt)
                Write-Progress -Activity $Activity -Status ("Compressing... {0}" -f $done)
              }
            }
          }
        }
      }
    } catch {
      $readFails++
      if ($readFails -eq 20) { Write-Host "  Warning: unable to read ffmpeg output, progress will not be shown." -ForegroundColor Yellow }
    }
  }
  # Read remaining output after process exits.
  try {
    if (Test-Path $statsFile) {
      $full = Get-Content $statsFile -Raw -ErrorAction Stop
      if ($null -eq $full) { $full = "" }
      if ($full.Length -gt $consumed) {
        $newText = $full.Substring($consumed)
        $segments = $newText -split "[`r`n]+"
        foreach ($seg in $segments) {
          $seg = $seg.Trim()
          if ($seg -eq "") { continue }
          if (-not $seg.StartsWith("frame=")) { Write-Host $seg }
        }
      }
    }
  } catch { }
  Write-Host ""
  $proc.WaitForExit()
  $code = $proc.ExitCode
  if (($code -eq 0) -and ($duration -gt 0)) {
    Write-Progress -Activity $Activity -Status ("100% - {0} / {0}" -f $total) -PercentComplete 100
  }
  Write-Progress -Activity $Activity -Completed
  if (($code -ne 0) -and (Test-Path $statsFile)) {
    $errTail = Get-Content $statsFile -Tail 5 -ErrorAction SilentlyContinue
    if ($errTail) { $errTail | ForEach-Object { Write-Host "  ffmpeg: $_" -ForegroundColor Red } }
  }
  try { Remove-Item $statsFile -ErrorAction SilentlyContinue } catch { }
  try { Remove-Item $outFile -ErrorAction SilentlyContinue } catch { }
  return $code
}

function Compress-One($In) {
  $In = Clean-Path $In
  if (-not (Test-Path $In)) { Write-Host "  File not found: $In" -ForegroundColor Red; return }
  $dir  = Split-Path $In -Parent; if (-not $dir) { $dir = "." }
  $base = [IO.Path]::GetFileNameWithoutExtension($In)
  $outDirPath = if ($OutputDir) { $OutputDir } else { Join-Path $dir "compressed" }
  New-Item -ItemType Directory -Force -Path $outDirPath | Out-Null
  $out = Join-Path $outDirPath "${base}_compressed.mp4"

  $vf = @()
  if ($script:EffectiveResolusi) { $vf = @("-vf", "scale=-2:$($script:EffectiveResolusi):force_original_aspect_ratio=decrease") }

  $before = (Get-Item $In).Length
  $gpuLabel = if ($script:UseGpu) { "GPU" } else { "CPU" }
  Write-Host "`n> $In  [preset=$Preset crf=$script:Crf $gpuLabel] -> $out"

  $ok = $false
  $activity = "Compressing $base"
  if ($script:UseGpu -and $script:Codec -eq "libx264") {
    $ffArgs = @("-y", "-hide_banner", "-loglevel", "error", "-i", $In) + $vf + @("-c:v", "h264_nvenc", "-preset", "p5", "-tune", "hq", "-cq", "$script:Crf", "-b:v", "0", "-c:a", "aac", "-b:a", $script:AB, "-pix_fmt", "yuv420p", "-movflags", "+faststart", $out)
    $code = Invoke-FfmpegWithProgress -InputFile $In -FfmpegArgs $ffArgs -Activity $activity
    if (($code -eq 0) -and (Test-Path $out)) {
      $ok = $true
    } else {
      # Secondary safety net: NVENC failed mid-run, retry automatically on CPU.
      Write-Host "  GPU failed mid-run, retrying automatically on CPU..." -ForegroundColor Yellow
      $script:UseGpu = $false
      $script:GpuFallback = $true
      Save-Settings
      $ffArgs = @("-y", "-hide_banner", "-loglevel", "error", "-i", $In) + $vf + @("-c:v", "libx264", "-preset", $script:FP, "-crf", "$script:Crf", "-c:a", "aac", "-b:a", $script:AB, "-pix_fmt", "yuv420p", "-movflags", "+faststart", $out)
      $code = Invoke-FfmpegWithProgress -InputFile $In -FfmpegArgs $ffArgs -Activity $activity
      if (($code -eq 0) -and (Test-Path $out)) { $ok = $true }
    }
  } elseif ($script:Codec -eq "libx265") {
    $ffArgs = @("-y", "-hide_banner", "-loglevel", "error", "-i", $In) + $vf + @("-c:v", "libx265", "-preset", $script:FP, "-crf", "$script:Crf", "-x265-params", "log-level=error", "-c:a", "aac", "-b:a", $script:AB, "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-tag:v", "hvc1", $out)
    $code = Invoke-FfmpegWithProgress -InputFile $In -FfmpegArgs $ffArgs -Activity $activity
    if (($code -eq 0) -and (Test-Path $out)) { $ok = $true }
  } else {
    $ffArgs = @("-y", "-hide_banner", "-loglevel", "error", "-i", $In) + $vf + @("-c:v", "libx264", "-preset", $script:FP, "-crf", "$script:Crf", "-c:a", "aac", "-b:a", $script:AB, "-pix_fmt", "yuv420p", "-movflags", "+faststart", $out)
    $code = Invoke-FfmpegWithProgress -InputFile $In -FfmpegArgs $ffArgs -Activity $activity
    if (($code -eq 0) -and (Test-Path $out)) { $ok = $true }
  }

  if (-not $ok) { Write-Host "  FAILED: output file was not created. Check ffmpeg error above." -ForegroundColor Red; return }
  $after = (Get-Item $out).Length
  $pct = [math]::Round((1 - $after/$before)*100, 1)
  Write-Host ("  OK {0:N1} MB -> {1:N1} MB (saved {2}%)" -f ($before/1MB), ($after/1MB), $pct) -ForegroundColor Green
}

foreach ($target in $Path) {
  $target = Clean-Path $target
  if (Test-Path $target -PathType Container) {
    Get-ChildItem $target -Include *.mp4,*.mov,*.mkv,*.avi,*.webm -File | ForEach-Object { Compress-One $_.FullName }
  } else {
    $resolved = (Resolve-Path $target -ErrorAction SilentlyContinue).Path
    if ($resolved) { Compress-One $resolved }
    else { Write-Host "  File not found: $target" -ForegroundColor Red }
  }
}
Write-Host "`nDone."
