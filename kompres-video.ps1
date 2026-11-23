<#
Kompres video pakai ffmpeg - versi Windows PowerShell, INTERAKTIF
===============================================================
TIGA CARA PAKAI:
  1. Double-click kompres-video.bat (tanpa file) -> menu muncul duluan.
     Ketik angka lalu Enter:
       [0] GPU on/off
       [1] Ganti preset (kualitas / ukuran file)
       [2] Ganti resolusi
       [3] Kirim / ganti path video
       [4] Ganti folder output
       [5] Mulai kompres (atau tekan Enter saja)
       [9] Keluar
  2. Drag & drop file video ke kompres-video.bat, atau
     .\kompres-video.ps1 "D:\video.mp4"
     -> LANGSUNG kompres pakai setting terakhir, tanpa menu.
     Mau ubah setting dulu? Jalankan dengan -Menu.
  3. Tanpa menu sama sekali (otomatisasi):
     .\kompres-video.ps1 -NoMenu video.mp4

SETTING TERSIMPAN:
  Setiap kali selesai (atau keluar dari menu), setting terakhir
  disimpan di kompres-video-settings.json di sebelah script ini.
  Buka lagi besok, settingnya tetap seperti terakhir.

GPU:
  Kalau GPU dinyalakan tapi NVENC tidak terdeteksi / gagal jalan,
  script otomatis pindah ke CPU dan memberitahumu. Tidak perlu
  menebak-nebak driver atau setting.
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

# --- Setting tersimpan (JSON di sebelah script) ---
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
    # Gagal simpan bukan fatal - kompres tetap jalan.
  }
}

function Test-GpuAvailable {
  if ($script:GpuTested) { return $script:GpuAvailable }
  $script:GpuTested = $true
  $script:GpuAvailable = $false
  $tmp = Join-Path $env:TEMP "gpu-test-nvenc.mp4"
  try { Remove-Item $tmp -ErrorAction SilentlyContinue } catch { }
  # Tes encode 0,1 detik pakai NVENC. Kalau driver tidak cocok / tidak ada
  # GPU NVIDIA, perintah ini gagal (exit code bukan 0).
  & ffmpeg -y -hide_banner -loglevel error -f lavfi -i "color=c=black:s=128x128:d=0.1" -c:v h264_nvenc -preset p1 -f mp4 $tmp 2>$null
  $code = $LASTEXITCODE
  if (($code -eq 0) -and (Test-Path $tmp)) { $script:GpuAvailable = $true }
  try { Remove-Item $tmp -ErrorAction SilentlyContinue } catch { }
  return $script:GpuAvailable
}

function Get-PresetLabel([string]$p) {
  switch ($p) {
    "ringan"   { return "ringan (H.264, CRF 20 - kualitas tinggi)" }
    "seimbang" { return "seimbang (H.264, CRF 23 - rekomendasi)" }
    "youtube"  { return "youtube (H.264, CRF 18 - buat di-upload)" }
    "kecil"    { return "kecil (H.264, CRF 28 + 720p - sekecil mungkin)" }
    "265"      { return "265 (H.265, CRF 26 - paling kecil, encode lama)" }
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
  # Preset kecil otomatis turun ke 720p kalau resolusi tidak diisi manual.
  $script:EffectiveResolusi = $Resolusi
  if ($Preset -eq "kecil" -and -not $script:EffectiveResolusi) { $script:EffectiveResolusi = "720" }
}

function Show-Status {
  Write-Host ""
  Write-Host "==============================" -ForegroundColor Cyan
  Write-Host "  KOMPRES VIDEO" -ForegroundColor Cyan
  Write-Host "==============================" -ForegroundColor Cyan
  if (-not $Path -or $Path.Count -eq 0) {
    Write-Host "  File    : (belum ada - pilih [3] untuk kirim path video)" -ForegroundColor Yellow
  }
  foreach ($t in $Path) {
    $clean = Clean-Path $t
    if (Test-Path $clean -PathType Container) {
      $n = (Get-ChildItem $clean -Include *.mp4,*.mov,*.mkv,*.avi,*.webm -File -ErrorAction SilentlyContinue).Count
      Write-Host "  File    : $clean  ($n video di folder)"
    } elseif (Test-Path $clean) {
      $mb = [math]::Round((Get-Item $clean).Length / 1MB, 1)
      Write-Host "  File    : $clean  ($mb MB)"
    } else {
      Write-Host "  File    : $clean  (tidak ketemu!)" -ForegroundColor Red
    }
  }
  Write-Host "  Preset  : $(Get-PresetLabel $Preset)"
  if ($Resolusi) { Write-Host "  Resolusi: ${Resolusi}p" }
  elseif ($Preset -eq "kecil") { Write-Host "  Resolusi: asli -> 720p (otomatis preset kecil)" }
  else { Write-Host "  Resolusi: asli (tidak diubah)" }
  if ($script:GpuFallback) {
    Write-Host "  GPU     : OFF (fallback - NVENC tidak terdeteksi, pakai CPU)" -ForegroundColor Yellow
  } elseif ($script:UseGpu) {
    Write-Host "  GPU     : ON  (NVENC, cepat)"
  } else {
    Write-Host "  GPU     : OFF (CPU, stabil)"
  }
  $outText = if ($OutputDir) { $OutputDir } else { "folder compressed/ di sebelah file sumber" }
  Write-Host "  Output  : $outText"
  Write-Host "  Setting : tersimpan otomatis, dibuka lagi tetap seperti ini"
  Write-Host ""
}

function Choose-Preset {
  Write-Host ""
  Write-Host "Pilih preset:"
  Write-Host "  [1] ringan   - CRF 20, kualitas tinggi, file masih cukup besar"
  Write-Host "  [2] seimbang - CRF 23, sweet spot kualitas vs ukuran (default)"
  Write-Host "  [3] youtube  - CRF 18, kualitas upload"
  Write-Host "  [4] kecil    - CRF 28 + 720p, ukuran sekecil mungkin"
  Write-Host "  [5] 265      - H.265 CRF 26, file paling kecil, encode lebih lama"
  Write-Host "  [9] kembali"
  $c = (Read-Host "Pilih preset [2]").Trim()
  if ($c -eq "") { $c = "2" }
  switch ($c) {
    "1" { $script:Preset = "ringan" }
    "2" { $script:Preset = "seimbang" }
    "3" { $script:Preset = "youtube" }
    "4" { $script:Preset = "kecil" }
    "5" { $script:Preset = "265" }
    "9" { }
    default { Write-Host "Pilihan tidak dikenal, preset tidak diubah." -ForegroundColor Yellow }
  }
}

function Choose-Resolusi {
  Write-Host ""
  Write-Host "Pilih resolusi:"
  Write-Host "  [1] Asli (tidak diubah)"
  Write-Host "  [2] 1080p"
  Write-Host "  [3] 720p"
  Write-Host "  [4] 480p"
  Write-Host "  [9] kembali"
  $c = (Read-Host "Pilih resolusi [1]").Trim()
  if ($c -eq "") { $c = "1" }
  switch ($c) {
    "1" { $script:Resolusi = "" }
    "2" { $script:Resolusi = "1080" }
    "3" { $script:Resolusi = "720" }
    "4" { $script:Resolusi = "480" }
    "9" { }
    default { Write-Host "Pilihan tidak dikenal, resolusi tidak diubah." -ForegroundColor Yellow }
  }
}

function Ask-Path {
  Write-Host ""
  Write-Host "Masukkan path file / folder video."
  Write-Host "Tips: drag file videonya ke jendela ini, lalu tekan Enter. Boleh pakai / tanpa tanda kutip."
  $p = Read-Host "Path file video"
  if (-not $p -or -not $p.Trim()) { return $false }
  $script:Path = @(Clean-Path $p)
  return $true
}

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  Write-Host "ffmpeg belum ada di PATH. Install dulu: winget install Gyan.FFmpeg" -ForegroundColor Red; exit 1
}

# --- Muat setting terakhir, lalu parameter yang diketik eksplisit menang ---
$explicitPreset = $null; if ($PSBoundParameters.ContainsKey('Preset')) { $explicitPreset = $Preset }
$explicitResolusi = $null; if ($PSBoundParameters.ContainsKey('Resolusi')) { $explicitResolusi = $Resolusi }
$explicitOutputDir = $null; if ($PSBoundParameters.ContainsKey('OutputDir')) { $explicitOutputDir = $OutputDir }
$explicitGpu = $null; if ($PSBoundParameters.ContainsKey('Gpu')) { $explicitGpu = [bool]$Gpu }
Load-Settings | Out-Null
if ($null -ne $explicitPreset) { $script:Preset = $explicitPreset }
if ($null -ne $explicitResolusi) { $script:Resolusi = $explicitResolusi }
if ($null -ne $explicitOutputDir) { $script:OutputDir = $explicitOutputDir }
if ($null -ne $explicitGpu) { $script:UseGpu = $explicitGpu }

# Bersihkan kutip dari path yang dikirim lewat drag & drop / paste.
if ($Path -and $Path.Count -gt 0) { $script:Path = @($Path | ForEach-Object { Clean-Path $_ }) }

# --- Kapan menu muncul, kapan langsung jalan? ---
# -Menu           -> menu muncul (walau path sudah dikirim)
# -NoMenu         -> langsung kompres, tanpa menu
# Tanpa path      -> menu muncul (belum ada file yang bisa dikompres)
# Path dikirim    -> LANGSUNG kompres pakai setting terakhir, tanpa menu
$showMenu = $false
if ($NoMenu) { $showMenu = $false }
elseif ($Menu) { $showMenu = $true }
elseif (-not $Path -or $Path.Count -eq 0) { $showMenu = $true }
else { $showMenu = $false }

# --- Menu interaktif ---
if ($showMenu) {
  $startCompress = $false
  while (-not $startCompress) {
    Update-Settings
    Show-Status
    Write-Host "  [0] GPU on/off (saat ini: $(if ($script:UseGpu) { 'ON' } else { 'OFF' }))"
    Write-Host "  [1] Ganti preset (kualitas / ukuran file)"
    Write-Host "  [2] Ganti resolusi"
    Write-Host "  [3] Kirim / ganti path video"
    Write-Host "  [4] Ganti folder output"
    Write-Host "  [5] Mulai kompres (pakai setting di atas)"
    Write-Host "  [9] Keluar"
    $choice = (Read-Host "Pilih [5]").Trim()
    if ($choice -eq "") { $choice = "5" }
    # Buang tanda kutip dulu: drag file ke jendela PowerShell menempel
    # path pakai kutip ("D:\...mp4"), dan kutip itu membuat pengecekan
    # path di bawah gagal (pilihan tidak dikenal).
    $choice = Clean-Path $choice
    # Kalau yang diketik ternyata path video langsung, pakai sebagai file
    # dan LANGSUNG mulai kompres (tidak kembali ke menu lagi).
    if ($choice -match '^[A-Za-z]:\\' -or $choice -match '\.(mp4|mov|mkv|avi|webm)$') {
      $script:Path = @(Clean-Path $choice)
      $startCompress = $true
      continue
    }
    if ($choice -eq "5") {
      if (-not $Path -or $Path.Count -eq 0) {
        Write-Host "Belum ada file video. Kirim path-nya dulu." -ForegroundColor Yellow
        if (Ask-Path) { $startCompress = $true }
      } else {
        $startCompress = $true
      }
    } elseif ($choice -eq "0") {
      if (-not $script:UseGpu) {
        Write-Host "Mengecek GPU (NVENC)..."
        if (Test-GpuAvailable) {
          $script:UseGpu = $true
          $script:GpuFallback = $false
          Write-Host "GPU terdeteksi, NVENC aktif."
        } else {
          Write-Host "GPU tidak terdeteksi / NVENC tidak jalan, tetap pakai CPU." -ForegroundColor Yellow
        }
      } else {
        $script:UseGpu = $false
        Write-Host "GPU dimatikan, pakai CPU."
      }
    } elseif ($choice -eq "1") {
      Choose-Preset
    } elseif ($choice -eq "2") {
      Choose-Resolusi
    } elseif ($choice -eq "3") {
      # Kirim path -> langsung mulai kompres, tidak kembali ke menu.
      # (Setting sudah terlihat di menu sebelum pilih [3], jadi kalau
      # mau ubah preset / resolusi / GPU dulu, ubah sebelum pilih [3].)
      if (Ask-Path) { $startCompress = $true }
    } elseif ($choice -eq "4") {
      $o = Read-Host "Folder output (kosong = folder compressed/ default)"
      $script:OutputDir = $o.Trim().Trim('"')
    } elseif ($choice -eq "9") {
      Save-Settings
      Write-Host "Setting tersimpan. Dibatalkan."; exit 0
    } else {
      Write-Host "Pilihan tidak dikenal, coba 0-5 atau 9." -ForegroundColor Yellow
    }
  }
}

Update-Settings

# --- GPU on tapi tidak terdeteksi -> otomatis pindah ke CPU ---
if ($script:UseGpu) {
  if (-not (Test-GpuAvailable)) {
    Write-Host ""
    Write-Host "GPU tidak terdeteksi / NVENC tidak jalan, otomatis pindah ke CPU." -ForegroundColor Yellow
    $script:UseGpu = $false
    $script:GpuFallback = $true
  }
}

# Simpan setting terakhir sebelum kompres, supaya dibuka lagi tetap sama.
Save-Settings

if (-not $Path -or $Path.Count -eq 0) {
  Write-Host "Tidak ada file video. Jalankan lagi dan kirim path videonya." -ForegroundColor Red; exit 1
}

function Get-VideoDuration([string]$file) {
  # Coba ffprobe dulu (paling akurat).
  try {
    $raw = & ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $file 2>$null
    $sec = 0.0
    if ($raw -and [double]::TryParse($raw.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$sec) -and $sec -gt 0) { return $sec }
  } catch { }
  # Cadangan: baca "Duration: 00:14:00.00" dari ffmpeg -i.
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
  # -stats menghidupkan lagi output per detik ffmpeg (frame/fps/time/bitrate/speed).
  # stderr dialihkan ke file supaya bisa dibaca sambil jalan: baris stats
  # ditampilkan lagi di layar (persis seperti dulu) DAN dipakai menghitung persen,
  # jadi persen dan angka time= di layar selalu cocok (satu sumber yang sama).
  $allArgs = @("-stats") + $FfmpegArgs
  $argString = ($allArgs | ForEach-Object { if ($_ -match '\s') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  $proc = $null
  try {
    $proc = Start-Process -FilePath "ffmpeg" -ArgumentList $argString -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $statsFile -ErrorAction Stop
  } catch {
    Write-Host "  Tidak bisa menjalankan ffmpeg: $($_.Exception.Message)" -ForegroundColor Red
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
        # JANGAN pakai [IO.File]::ReadAllText di sini: dia membuka file
        # dengan FileShare.Read saja dan selalu gagal selama ffmpeg masih
        # menulis file ini. Get-Content memakai FileShare.ReadWrite.
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
              # Baris lain dari ffmpeg (error dsb.) - tampilkan apa adanya, sekali saja.
              Write-Host $seg
            }
          }
          if ($lastStats -ne "") {
            # Tampilkan baris stats di tempat yang sama (seperti ffmpeg dulu).
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
                Write-Progress -Activity $Activity -Status ("Mengompres... {0}" -f $done)
              }
            }
          }
        }
      }
    } catch {
      $readFails++
      if ($readFails -eq 20) { Write-Host "  Peringatan: tidak bisa membaca output ffmpeg, progres tidak tampil." -ForegroundColor Yellow }
    }
  }
  # Baca sisa output setelah proses selesai (ringkasan akhir).
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
  if (-not (Test-Path $In)) { Write-Host "  File tidak ketemu: $In" -ForegroundColor Red; return }
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
  $activity = "Mengompres $base"
  if ($script:UseGpu -and $script:Codec -eq "libx264") {
    $ffArgs = @("-y", "-hide_banner", "-loglevel", "error", "-i", $In) + $vf + @("-c:v", "h264_nvenc", "-preset", "p5", "-tune", "hq", "-cq", "$script:Crf", "-b:v", "0", "-c:a", "aac", "-b:a", $script:AB, "-pix_fmt", "yuv420p", "-movflags", "+faststart", $out)
    $code = Invoke-FfmpegWithProgress -InputFile $In -FfmpegArgs $ffArgs -Activity $activity
    if (($code -eq 0) -and (Test-Path $out)) {
      $ok = $true
    } else {
      # Jaring pengaman kedua: NVENC gagal di tengah jalan, ulangi pakai CPU.
      Write-Host "  GPU gagal di tengah jalan, ulangi otomatis pakai CPU..." -ForegroundColor Yellow
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

  if (-not $ok) { Write-Host "  GAGAL: file hasil tidak terbentuk. Cek error ffmpeg di atas." -ForegroundColor Red; return }
  $after = (Get-Item $out).Length
  $pct = [math]::Round((1 - $after/$before)*100, 1)
  Write-Host ("  OK {0:N1} MB -> {1:N1} MB (hemat {2}%)" -f ($before/1MB), ($after/1MB), $pct) -ForegroundColor Green
}

foreach ($target in $Path) {
  $target = Clean-Path $target
  if (Test-Path $target -PathType Container) {
    Get-ChildItem $target -Include *.mp4,*.mov,*.mkv,*.avi,*.webm -File | ForEach-Object { Compress-One $_.FullName }
  } else {
    $resolved = (Resolve-Path $target -ErrorAction SilentlyContinue).Path
    if ($resolved) { Compress-One $resolved }
    else { Write-Host "  File tidak ketemu: $target" -ForegroundColor Red }
  }
}
Write-Host "`nSelesai."
