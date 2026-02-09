# ISS Live Wallpaper

Live video from the International Space Station as your macOS desktop wallpaper.

Captures 30-second video loops from NASA's ISS HD live stream on YouTube, plays them as a seamless looping video wallpaper with smooth crossfades between updates. During ISS night passes, the wallpaper freezes on the last good daylight frame.

## How It Works

```
┌─────────────────────┐     ┌──────────────────────────┐
│  iss-capture-loop.sh │     │  iss-video-wallpaper     │
│  (runs every 45s)    │     │  (always running)        │
│                      │     │                          │
│  1. yt-dlp → HLS URL │     │  Borderless NSWindow at  │
│  2. Brightness check │     │  desktop level with dual  │
│  3. ffmpeg → 30s MP4 │────▶│  AVPlayerLayers.         │
│  4. Write loop_a/b   │     │  Polls for new loops,    │
│                      │     │  crossfades over 2s.     │
└─────────────────────┘     └──────────────────────────┘
```

**A/B swap pattern:** Two loop files (`loop_a.mp4` / `loop_b.mp4`) alternate. The capture script writes to whichever is older; the app detects the change and crossfades. Only two files ever exist on disk (~15MB peak).

**Night pass detection:** Before each 30-second capture, a single frame is grabbed and its average brightness measured (0-255). If below threshold (default 20), the capture is skipped and the current loop keeps playing.

**Stream URL caching:** YouTube HLS URLs are valid ~6 hours. The URL is cached and only refreshed when it expires or ffmpeg fails. This cuts per-cycle overhead from ~5s to ~2s.

## Prerequisites

- macOS 14+ (Sonoma, Sequoia, or Tahoe)
- Apple Silicon or Intel Mac
- Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh)

## Install

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

## Uninstall

```bash
./uninstall.sh
```

Stops services, removes binaries, LaunchAgents, and cached data. Dependencies are left installed.

## Configuration

Edit `iss-capture-loop.sh` to change:

| Variable | Default | Description |
|---|---|---|
| `YOUTUBE_ID` | `aB1yRz0HhdY` | NASA ISS HD stream video ID |
| `LOOP_DURATION` | `30` | Seconds per loop |
| `BRIGHTNESS_THRESHOLD` | `20` | 0-255; below = too dark (night pass) |
| `MAX_URL_AGE` | `18000` | Seconds before refreshing YouTube URL |

Edit `ISSVideoWallpaper.swift` to change crossfade duration (`fadeSecs`, default 2.0 seconds). Recompile after changes:

```bash
swiftc -O -o ~/.local/bin/iss-video-wallpaper ISSVideoWallpaper.swift \
    -framework AppKit -framework AVFoundation -framework QuartzCore
```

## Management

```bash
# View log
tail -20 ~/.local/share/iss-wallpaper/iss-wallpaper.log

# Check loop files
ls -lh ~/.local/share/iss-wallpaper/loops/

# Check disk usage
du -sh ~/.local/share/iss-wallpaper/

# Stop
launchctl bootout gui/$(id -u)/com.simonlowes.iss-video-wallpaper
launchctl bootout gui/$(id -u)/com.simonlowes.iss-capture-loop

# Restart
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.simonlowes.iss-video-wallpaper.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.simonlowes.iss-capture-loop.plist

# Force immediate capture
~/.local/bin/iss-capture-loop.sh
```

## Architecture

| File | Purpose |
|---|---|
| `ISSVideoWallpaper.swift` | macOS app — borderless desktop-level window with dual AVPlayerLayer crossfade |
| `iss-capture-loop.sh` | Captures 30s loops from NASA ISS YouTube stream via ffmpeg |
| `install.sh` | Compiles, installs, and loads LaunchAgents |
| `uninstall.sh` | Stops, removes, and cleans up everything |

| Runtime File | Purpose |
|---|---|
| `~/.local/bin/iss-video-wallpaper` | Compiled binary |
| `~/.local/bin/iss-capture-loop.sh` | Capture script |
| `~/.local/share/iss-wallpaper/loops/` | Video loops (max 2 files, ~15MB) |
| `~/.local/share/iss-wallpaper/stream_url` | Cached YouTube HLS URL |
| `~/.local/share/iss-wallpaper/iss-wallpaper.log` | Combined log (auto-trimmed to 500 lines) |

## Resource Usage

| Component | CPU | RAM | Disk |
|---|---|---|---|
| Video wallpaper app | ~2% | ~40MB | — |
| Capture (during recording) | ~18% | ~30MB | ~15MB peak |
| Capture (idle) | 0% | 0 | — |

## How the ISS Stream Works

The ISS orbits Earth every ~90 minutes. Each orbit has ~45 minutes of daylight and ~45 minutes of darkness. During night passes, the external camera shows a black screen. The brightness pre-check skips captures during these periods, keeping your wallpaper on the last good daylight view.

If NASA's YouTube stream goes down or the video ID changes, update `YOUTUBE_ID` in the capture script. Current known IDs:
- `aB1yRz0HhdY` — NASA ISS HD (720p, official)
- `fO9e9jnhYK8` — Sen SpaceTV-1 4K

## License

MIT
