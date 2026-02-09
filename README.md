# ISS Live Wallpaper

Live video from the International Space Station as your desktop wallpaper.

Captures 30-second video loops from NASA's ISS HD live stream on YouTube, plays them as a seamless looping video wallpaper. During ISS night passes, the wallpaper freezes on the last good daylight frame.

## Platform Support

| | macOS | Linux | Windows |
|---|---|---|---|
| **Wallpaper player** | Custom Swift app (AVPlayerLayer) | mpvpaper (Wayland) / xwinwrap + mpv (X11) | Lively Wallpaper |
| **Capture script** | Bash (native) | Bash (native) | PowerShell (native) or Bash (WSL) |
| **Auto-start** | launchd | systemd user services | Task Scheduler + Lively auto-start |
| **HW encoding** | VideoToolbox | VAAPI / NVENC | NVENC / AMF / QSV |
| **Crossfade** | 2s smooth crossfade | Hard cut (mpv limitation) | Hard cut (Lively limitation) |
| **Multi-monitor** | Automatic | `'*'` (mpvpaper) / geometry flags (xwinwrap) | Per-screen, span, or duplicate |

## How It Works

```
┌─────────────────────┐     ┌──────────────────────────┐
│  Capture Script      │     │  Wallpaper Player         │
│  (runs every 45s)    │     │  (always running)         │
│                      │     │                           │
│  1. yt-dlp → HLS URL │     │  Plays loop video at      │
│  2. Brightness check │     │  desktop level, detects    │
│  3. ffmpeg → 30s MP4 │────▶│  new files and swaps.     │
│  4. Write loop_a/b   │     │                           │
└─────────────────────┘     └──────────────────────────┘
```

**A/B swap pattern:** Two loop files (`loop_a.mp4` / `loop_b.mp4`) alternate. The capture script writes to whichever is older; the player detects the change and switches. Only two files ever exist on disk (~15MB peak).

**Night pass detection:** Before each 30-second capture, a single frame is grabbed and its average brightness measured (0–255). If below threshold (default 20), the capture is skipped and the current loop keeps playing.

**Stream URL caching:** YouTube HLS URLs are valid ~6 hours. The URL is cached and only refreshed when it expires or ffmpeg fails.

---

## macOS

### Prerequisites

- macOS 14+ (Sonoma, Sequoia, or Tahoe)
- Apple Silicon or Intel Mac
- Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh)

### Install

```bash
git clone <this-repo>
cd iss-live-wallpaper
chmod +x install.sh uninstall.sh
./install.sh
```

The installer:
1. Installs dependencies via Homebrew (ffmpeg, yt-dlp, desktoppr)
2. Compiles the Swift video wallpaper app
3. Installs scripts to `~/.local/bin/`
4. Creates and loads LaunchAgents (auto-start on login)

The first video loop takes ~30 seconds to capture. Your desktop will be black until then.

### Uninstall

```bash
./uninstall.sh
```

Stops services, removes binaries, LaunchAgents, and cached data. Dependencies are left installed.

### Management

```bash
# View log
tail -20 ~/.local/share/iss-wallpaper/iss-wallpaper.log

# Check loop files
ls -lh ~/.local/share/iss-wallpaper/loops/

# Stop
launchctl bootout gui/$(id -u)/com.simonlowes.iss-video-wallpaper
launchctl bootout gui/$(id -u)/com.simonlowes.iss-capture-loop

# Restart
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.simonlowes.iss-video-wallpaper.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.simonlowes.iss-capture-loop.plist

# Force immediate capture
~/.local/bin/iss-capture-loop.sh
```

---

## Linux

The capture script works on Linux with minor modifications (`stat` syntax and hardware encoder). The wallpaper player depends on whether you're running Wayland or X11.

### Prerequisites

- A Linux distribution with systemd (Ubuntu 20.04+, Fedora 36+, Arch, etc.)
- Wayland (wlroots-based: Sway, Hyprland, River) **or** X11
- ffmpeg, yt-dlp, mpv, socat

```bash
# Ubuntu / Debian
sudo apt install ffmpeg yt-dlp mpv socat inotify-tools

# Fedora
sudo dnf install ffmpeg yt-dlp mpv socat inotify-tools

# Arch
sudo pacman -S ffmpeg yt-dlp mpv socat inotify-tools
```

### Wallpaper Player

#### Wayland (wlroots compositors: Sway, Hyprland, River)

Install [mpvpaper](https://github.com/GhostNaN/mpvpaper):

```bash
# Arch (AUR)
yay -S mpvpaper

# Ubuntu / Debian / Fedora (build from source)
sudo apt install build-essential meson ninja-build pkg-config libmpv-dev libwayland-dev wayland-protocols
git clone https://github.com/GhostNaN/mpvpaper /tmp/mpvpaper
cd /tmp/mpvpaper && meson setup build --prefix=/usr/local && ninja -C build && sudo ninja -C build install
```

Run:

```bash
mpvpaper -f -p \
  -o "--loop --no-audio --panscan=1 --hwdec=auto --input-ipc-server=/tmp/mpvpaper-socket" \
  '*' ~/.local/share/iss-wallpaper/loops/loop_a.mp4
```

- `'*'` targets all monitors. Use output names like `DP-1` or `HDMI-A-1` for specific monitors.
- `-p` pauses playback when the wallpaper is hidden (saves CPU).

> **Note:** mpvpaper only works with wlroots-based compositors. It does **not** work on GNOME (Mutter) or KDE (KWin). GNOME users should look at [Hidamari](https://flathub.org/apps/io.github.jeffshee.Hidamari). KDE Plasma 6 users can try [Smart Video Wallpaper Reborn](https://github.com/luisbocanegra/plasma-smart-video-wallpaper-reborn).

#### X11 (any desktop environment)

Install [xwinwrap](https://github.com/mmhobi7/xwinwrap):

```bash
# Arch (AUR)
yay -S xwinwrap-git

# Ubuntu / Debian (build from source)
sudo apt install xorg-dev build-essential libx11-dev libxrender-dev libxext-dev
git clone https://github.com/mmhobi7/xwinwrap /tmp/xwinwrap
cd /tmp/xwinwrap && make && sudo make install
```

Run:

```bash
xwinwrap -ni -nf -b -fs -un -- mpv --wid=%WID \
  --loop-file=inf --no-audio --panscan=1.0 --hwdec=auto \
  --input-ipc-server=/tmp/xwinwrap-mpv-socket \
  ~/.local/share/iss-wallpaper/loops/loop_a.mp4
```

For multi-monitor, run one instance per monitor with geometry flags:

```bash
# Get monitor layout
xrandr --query | grep ' connected'

# Example: two 1920x1080 monitors side by side
xwinwrap -ni -nf -b -g 1920x1080+0+0 -un -- mpv --wid=%WID --loop-file=inf --no-audio /path/to/loop.mp4 &
xwinwrap -ni -nf -b -g 1920x1080+1920+0 -un -- mpv --wid=%WID --loop-file=inf --no-audio /path/to/loop.mp4 &
```

### Swapping Videos (A/B Pattern)

Both mpvpaper and xwinwrap use mpv, which supports IPC control via a JSON socket. When the capture script writes a new loop file, swap it in with:

```bash
# mpvpaper
echo '{"command":["loadfile","/path/to/loop_b.mp4","replace"]}' | socat - /tmp/mpvpaper-socket

# xwinwrap
echo '{"command":["loadfile","/path/to/loop_b.mp4","replace"]}' | socat - /tmp/xwinwrap-mpv-socket
```

A file watcher script automates this using `inotifywait`:

```bash
#!/usr/bin/env bash
# iss-watcher.sh — watches for new captures and swaps the wallpaper video
LOOP_DIR="${HOME}/.local/share/iss-wallpaper/loops"
SOCKET="/tmp/mpvpaper-socket"  # or /tmp/xwinwrap-mpv-socket

inotifywait -m -e close_write --format '%w%f' "$LOOP_DIR" | while read -r filepath; do
    [[ "$filepath" == *.mp4 ]] || continue
    sleep 0.5
    echo "{\"command\":[\"loadfile\",\"$filepath\",\"replace\"]}" | socat - "$SOCKET" 2>/dev/null
done
```

### Capture Script Changes

The macOS capture script needs two small changes for Linux:

| What | macOS | Linux |
|---|---|---|
| File modification time | `stat -f %m file` | `stat -c %Y file` |
| File size | `stat -f %z file` | `stat -c %s file` |
| Hardware encoding | `h264_videotoolbox` | Auto-detected (see below) |
| PATH | `/opt/homebrew/bin` | Not needed |

The script already falls back to `libx264` (software encoding) if hardware encoding fails, so it will work out of the box on any Linux system. For optimal performance, your hardware encoder is auto-detected:

- **Intel / AMD:** `h264_vaapi` (requires `/dev/dri/renderD128`)
- **NVIDIA:** `h264_nvenc` (requires proprietary drivers)
- **Fallback:** `libx264` (always works, slightly higher CPU)

### Auto-Start (systemd)

Create these files in `~/.config/systemd/user/`:

**`iss-capture.service`** — captures a loop when triggered by the timer:

```ini
[Unit]
Description=ISS Live Wallpaper - Capture Loop
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/iss-capture-loop.sh
```

**`iss-capture.timer`** — runs the capture every 45 seconds:

```ini
[Unit]
Description=ISS Live Wallpaper - Capture Timer

[Timer]
OnBootSec=30
OnUnitActiveSec=45
Persistent=true

[Install]
WantedBy=timers.target
```

**`iss-wallpaper.service`** — the video wallpaper player:

```ini
[Unit]
Description=ISS Live Wallpaper - Video Player
After=graphical-session.target

[Service]
Type=simple
# Wayland (mpvpaper) — adjust for X11 if needed
ExecStart=/usr/local/bin/mpvpaper -p -o "--loop --no-audio --panscan=1 --hwdec=auto --input-ipc-server=/tmp/mpvpaper-socket" '*' %h/.local/share/iss-wallpaper/loops/loop_a.mp4
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

**`iss-watcher.service`** — watches for new captures and swaps the video:

```ini
[Unit]
Description=ISS Live Wallpaper - File Change Watcher
After=iss-wallpaper.service

[Service]
Type=simple
ExecStart=%h/.local/bin/iss-watcher.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

Enable and start everything:

```bash
systemctl --user enable --now iss-capture.timer
systemctl --user enable --now iss-wallpaper.service
systemctl --user enable --now iss-watcher.service

# Optional: allow services to run before login
loginctl enable-linger $USER
```

### Management

```bash
# View log
tail -20 ~/.local/share/iss-wallpaper/iss-wallpaper.log

# View systemd logs
journalctl --user -u iss-capture.service -f

# Check timer status
systemctl --user status iss-capture.timer

# Stop everything
systemctl --user stop iss-capture.timer iss-wallpaper.service iss-watcher.service

# Restart
systemctl --user restart iss-capture.timer iss-wallpaper.service iss-watcher.service

# Disable auto-start
systemctl --user disable iss-capture.timer iss-wallpaper.service iss-watcher.service
```

---

## Windows

The Windows setup uses [Lively Wallpaper](https://github.com/rocksdanister/lively) (free, open-source) for video playback and either a PowerShell capture script (native) or the bash script via WSL2.

### Prerequisites

- Windows 10 (1903+) or Windows 11
- [Lively Wallpaper](https://github.com/rocksdanister/lively) — wallpaper player
- ffmpeg and yt-dlp

```powershell
# Install everything via winget
winget install rocksdanister.LivelyWallpaper
winget install yt-dlp.yt-dlp
winget install Gyan.FFmpeg
```

Or via [Chocolatey](https://chocolatey.org/):

```powershell
choco install yt-dlp ffmpeg-full lively
```

### Capture Script

#### Option A: PowerShell (Native, Recommended)

Save the following as `%USERPROFILE%\.local\bin\iss-capture-loop.ps1`:

```powershell
$ErrorActionPreference = "Stop"

$YOUTUBE_ID = "aB1yRz0HhdY"
$CACHE_DIR = "$env:USERPROFILE\.local\share\iss-wallpaper"
$LOOP_DIR = "$CACHE_DIR\loops"
$STREAM_URL_CACHE = "$CACHE_DIR\stream_url"
$TOGGLE_FILE = "$CACHE_DIR\.loop_toggle"
$LOG_FILE = "$CACHE_DIR\iss-wallpaper.log"
$LOOP_DURATION = 30
$BRIGHTNESS_THRESHOLD = 20
$MAX_URL_AGE = 18000

New-Item -ItemType Directory -Force -Path $LOOP_DIR | Out-Null

function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LOG_FILE -Value "$ts [capture] $msg"
    if (Test-Path $LOG_FILE) {
        $lines = (Get-Content $LOG_FILE).Count
        if ($lines -gt 1000) {
            Get-Content $LOG_FILE -Tail 500 | Set-Content $LOG_FILE
        }
    }
}

function Get-StreamUrl {
    if (Test-Path $STREAM_URL_CACHE) {
        $age = ((Get-Date) - (Get-Item $STREAM_URL_CACHE).LastWriteTime).TotalSeconds
        if ($age -lt $MAX_URL_AGE) {
            return (Get-Content $STREAM_URL_CACHE -Raw).Trim()
        }
    }
    $url = & yt-dlp -f "best[height<=1080]" -g "https://www.youtube.com/watch?v=$YOUTUBE_ID" 2>$null |
        Select-Object -First 1
    if ($url) {
        Set-Content -Path $STREAM_URL_CACHE -Value $url -NoNewline
        Write-Log "INFO: Refreshed stream URL"
        return $url
    }
    throw "Failed to get stream URL"
}

function Test-Brightness($streamUrl) {
    $tempFrame = "$CACHE_DIR\brightness_check.raw"
    & ffmpeg -i $streamUrl -vframes 1 -vf "scale=1:1" -pix_fmt gray `
        -f rawvideo -v quiet $tempFrame -y 2>$null
    if (-not (Test-Path $tempFrame)) { return $true }
    $bytes = [System.IO.File]::ReadAllBytes($tempFrame)
    Remove-Item $tempFrame -ErrorAction SilentlyContinue
    if ($bytes.Length -eq 0) { return $true }
    $brightness = [int]$bytes[0]
    Write-Log "INFO: Brightness pre-check: $brightness/255"
    return ($brightness -gt $BRIGHTNESS_THRESHOLD)
}

function Invoke-Capture($streamUrl, $output) {
    $temp = "$output.tmp.mp4"

    # Detect hardware encoder
    $encoders = & ffmpeg -encoders 2>$null
    $hwEnc = if ($encoders -match "h264_nvenc") { "h264_nvenc" }
             elseif ($encoders -match "h264_amf") { "h264_amf" }
             elseif ($encoders -match "h264_qsv") { "h264_qsv" }
             else { $null }

    if ($hwEnc) {
        & ffmpeg -i $streamUrl -t $LOOP_DURATION -c:v $hwEnc -b:v 2M `
            -an -movflags +faststart $temp -y 2>$null
        if ($LASTEXITCODE -eq 0) { Move-Item -Force $temp $output; return $true }
        Write-Log "WARN: $hwEnc failed, falling back to software"
    }

    & ffmpeg -i $streamUrl -t $LOOP_DURATION -c:v libx264 -crf 28 -preset fast `
        -an -movflags +faststart $temp -y 2>$null
    if ($LASTEXITCODE -eq 0) { Move-Item -Force $temp $output; return $true }
    Remove-Item $temp -ErrorAction SilentlyContinue
    return $false
}

# --- Main ---
try { $streamUrl = Get-StreamUrl }
catch {
    Remove-Item $STREAM_URL_CACHE -ErrorAction SilentlyContinue
    Write-Log "ERROR: Failed to get stream URL"
    exit 1
}

if (-not (Test-Brightness $streamUrl)) {
    Write-Log "SKIP: Dark frame (night pass), keeping current loop"
    exit 0
}

if (Test-Path $TOGGLE_FILE) {
    $target = "$LOOP_DIR\loop_a.mp4"
    Remove-Item $TOGGLE_FILE
} else {
    $target = "$LOOP_DIR\loop_b.mp4"
    New-Item -ItemType File -Force -Path $TOGGLE_FILE | Out-Null
}

if (Invoke-Capture $streamUrl $target) {
    $size = (Get-Item $target).Length
    $mb = [math]::Round($size / 1048576, 1)
    $name = Split-Path $target -Leaf
    Write-Log "OK: Captured ${LOOP_DURATION}s -> $name (${mb}MB)"
    & livelycu setwp --file $target
} else {
    Write-Log "ERROR: Capture failed, invalidating URL cache"
    Remove-Item $STREAM_URL_CACHE -ErrorAction SilentlyContinue
    exit 1
}
```

#### Option B: WSL2 (Bash)

If you prefer using the bash script, install WSL and run it there. The script needs the same `stat` changes as Linux:

```powershell
# Install WSL (PowerShell as Admin)
wsl --install

# Inside WSL (Ubuntu):
sudo apt update && sudo apt install -y ffmpeg
pip3 install yt-dlp
```

Output loop files to the Windows filesystem so Lively can read them:

```bash
CACHE_DIR="/mnt/c/Users/YourName/.local/share/iss-wallpaper"
```

Change `stat -f %m` to `stat -c %Y` and `stat -f %z` to `stat -c %s` (same as Linux).

### Wallpaper Player

Open Lively Wallpaper and enable **Start with Windows** in Settings.

Set the initial wallpaper via CLI:

```powershell
livelycu setwp --file "$env:USERPROFILE\.local\share\iss-wallpaper\loops\loop_a.mp4"
```

The PowerShell capture script calls `livelycu setwp` automatically after each capture, so Lively switches to the new loop file without needing a file watcher.

**Multi-monitor:** In Lively's Control Panel, choose a display layout:
- **Per** — same wallpaper on each screen independently
- **Span** — stretch across all monitors
- **Duplicate** — mirror primary to all screens

Or via CLI: `livelycu setwp --file "video.mp4" --monitor 0`

### Auto-Start (Task Scheduler)

Create a scheduled task to run the capture script every 45 seconds:

```powershell
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$env:USERPROFILE\.local\bin\iss-capture-loop.ps1`""

$trigger = New-ScheduledTaskTrigger `
    -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Seconds 45) `
    -RepetitionDuration ([TimeSpan]::MaxValue)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName "ISS Capture Loop" `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description "Captures 30-second video loops from the ISS live stream"
```

For WSL, replace the action with:

```powershell
$action = New-ScheduledTaskAction `
    -Execute "wsl.exe" `
    -Argument "-e bash -c '~/.local/bin/iss-capture-loop.sh'"
```

### Management

```powershell
# View log
Get-Content "$env:USERPROFILE\.local\share\iss-wallpaper\iss-wallpaper.log" -Tail 20

# Check loop files
Get-ChildItem "$env:USERPROFILE\.local\share\iss-wallpaper\loops"

# Run capture manually
& "$env:USERPROFILE\.local\bin\iss-capture-loop.ps1"

# Task Scheduler controls
Get-ScheduledTask -TaskName "ISS Capture Loop"        # Status
Start-ScheduledTask -TaskName "ISS Capture Loop"       # Run now
Stop-ScheduledTask -TaskName "ISS Capture Loop"        # Stop
Disable-ScheduledTask -TaskName "ISS Capture Loop"     # Pause
Enable-ScheduledTask -TaskName "ISS Capture Loop"      # Resume
Unregister-ScheduledTask -TaskName "ISS Capture Loop"  # Remove
```

### Uninstall

```powershell
# Stop and remove scheduled task
Unregister-ScheduledTask -TaskName "ISS Capture Loop" -Confirm:$false

# Remove data
Remove-Item -Recurse -Force "$env:USERPROFILE\.local\share\iss-wallpaper"
Remove-Item -Force "$env:USERPROFILE\.local\bin\iss-capture-loop.ps1"

# Uninstall Lively (optional)
winget uninstall rocksdanister.LivelyWallpaper
```

---

## Configuration

Edit the capture script to change:

| Variable | Default | Description |
|---|---|---|
| `YOUTUBE_ID` | `aB1yRz0HhdY` | NASA ISS HD stream video ID |
| `LOOP_DURATION` | `30` | Seconds per loop |
| `BRIGHTNESS_THRESHOLD` | `20` | 0–255; below = too dark (night pass) |
| `MAX_URL_AGE` | `18000` | Seconds before refreshing YouTube URL |

On macOS, edit `ISSVideoWallpaper.swift` to change crossfade duration (`fadeSecs`, default 2.0 seconds). Recompile after changes:

```bash
swiftc -O -o ~/.local/bin/iss-video-wallpaper ISSVideoWallpaper.swift \
    -framework AppKit -framework AVFoundation -framework QuartzCore
```

## Architecture

| File | Purpose |
|---|---|
| `ISSVideoWallpaper.swift` | macOS app — borderless desktop-level window with dual AVPlayerLayer crossfade |
| `iss-capture-loop.sh` | Captures 30s loops from NASA ISS YouTube stream via ffmpeg (macOS/Linux) |
| `install.sh` | macOS installer — compiles, installs, and loads LaunchAgents |
| `uninstall.sh` | macOS uninstaller — stops, removes, and cleans up everything |

| Runtime File | Purpose |
|---|---|
| `~/.local/share/iss-wallpaper/loops/` | Video loops (max 2 files, ~15MB) |
| `~/.local/share/iss-wallpaper/stream_url` | Cached YouTube HLS URL |
| `~/.local/share/iss-wallpaper/iss-wallpaper.log` | Combined log (auto-trimmed) |

On Windows, `~/.local/` is `%USERPROFILE%\.local\`.

## Resource Usage

| Component | CPU | RAM | Disk |
|---|---|---|---|
| Wallpaper player | ~2% | ~40MB | — |
| Capture (during recording) | ~18% | ~30MB | ~15MB peak |
| Capture (idle) | 0% | 0 | — |

## How the ISS Stream Works

The ISS orbits Earth every ~90 minutes. Each orbit has ~45 minutes of daylight and ~45 minutes of darkness. During night passes, the external camera shows a black screen. The brightness pre-check skips captures during these periods, keeping your wallpaper on the last good daylight view.

If NASA's YouTube stream goes down or the video ID changes, update `YOUTUBE_ID` in the capture script. Current known IDs:
- `aB1yRz0HhdY` — NASA ISS HD (720p, official)
- `fO9e9jnhYK8` — Sen SpaceTV-1 4K

## License

MIT
