#!/bin/bash
# Install ISS Live Wallpaper
# Compiles the Swift app, installs scripts, and loads LaunchAgents.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
DATA_DIR="$HOME/.local/share/iss-wallpaper"
AGENT_DIR="$HOME/Library/LaunchAgents"
UID_NUM=$(id -u)

echo "ISS Live Wallpaper — Install"
echo "=============================="
echo ""

# --- Check dependencies ---
echo "Checking dependencies..."
if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew is required to install dependencies but was not found on PATH."
    echo "  Install it from https://brew.sh and re-run this script."
    exit 1
fi
for cmd in ffmpeg yt-dlp; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "  Missing: $cmd — installing via Homebrew..."
        brew install "$cmd"
    else
        echo "  OK: $cmd"
    fi
done

if ! command -v desktoppr &>/dev/null; then
    echo "  Missing: desktoppr — installing via Homebrew..."
    brew install desktoppr
else
    echo "  OK: desktoppr"
fi

if ! command -v swiftc &>/dev/null; then
    echo "ERROR: swiftc not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi
echo "  OK: swiftc"
echo ""

# --- Create directories ---
echo "Creating directories..."
mkdir -p "$BIN_DIR" "$DATA_DIR/loops" "$AGENT_DIR"

# --- Compile Swift app ---
echo "Compiling video wallpaper app..."
swiftc -O \
    -o "$BIN_DIR/iss-video-wallpaper" \
    "$SCRIPT_DIR/ISSVideoWallpaper.swift" \
    -framework AppKit -framework AVFoundation -framework QuartzCore
echo "  Compiled: $BIN_DIR/iss-video-wallpaper"

# --- Install capture script ---
echo "Installing capture script..."
cp "$SCRIPT_DIR/iss-capture-loop.sh" "$BIN_DIR/iss-capture-loop.sh"
chmod +x "$BIN_DIR/iss-capture-loop.sh"
echo "  Installed: $BIN_DIR/iss-capture-loop.sh"

# --- Generate LaunchAgent plists (templated with $HOME) ---
echo "Installing LaunchAgents..."

cat > "$AGENT_DIR/com.simonlowes.iss-video-wallpaper.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.simonlowes.iss-video-wallpaper</string>
    <key>ProgramArguments</key>
    <array>
        <string>${HOME}/.local/bin/iss-video-wallpaper</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${HOME}/.local/share/iss-wallpaper/app-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.local/share/iss-wallpaper/app-stderr.log</string>
</dict>
</plist>
EOF

cat > "$AGENT_DIR/com.simonlowes.iss-capture-loop.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.simonlowes.iss-capture-loop</string>
    <key>ProgramArguments</key>
    <array>
        <string>${HOME}/.local/bin/iss-capture-loop.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>45</integer>
    <key>StandardOutPath</key>
    <string>${HOME}/.local/share/iss-wallpaper/capture-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.local/share/iss-wallpaper/capture-stderr.log</string>
</dict>
</plist>
EOF

echo "  Installed LaunchAgents"

# --- Unload if already running, then load ---
echo "Loading LaunchAgents..."

# Wait (with timeout) for a booted-out service to actually deregister before
# bootstrapping its replacement. bootout is asynchronous, so a fixed sleep is
# racy: if the old service is still registered, bootstrap fails with an error.
wait_for_unload() {
    local label="$1" i
    for ((i = 0; i < 50; i++)); do
        if ! launchctl print "gui/$UID_NUM/$label" &>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# Bootstrap a plist, reporting a clear error instead of aborting opaquely.
load_agent() {
    local plist="$1"
    if ! launchctl bootstrap "gui/$UID_NUM" "$plist"; then
        echo "ERROR: failed to load LaunchAgent: $plist"
        echo "  Try unloading any stale service first, then re-run this script:"
        echo "    launchctl bootout gui/$UID_NUM \"$plist\""
        exit 1
    fi
}

for label in com.simonlowes.iss-video-wallpaper com.simonlowes.iss-capture-loop; do
    launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
    wait_for_unload "$label" || echo "  Warning: $label still appears registered; attempting to load anyway."
done

load_agent "$AGENT_DIR/com.simonlowes.iss-video-wallpaper.plist"
load_agent "$AGENT_DIR/com.simonlowes.iss-capture-loop.plist"

echo ""
echo "Done! ISS Live Wallpaper is now running."
echo ""
echo "The first video loop takes ~30 seconds to capture."
echo "Your desktop will show a black screen until then."
echo ""
echo "Useful commands:"
echo "  tail -20 ~/.local/share/iss-wallpaper/iss-wallpaper.log"
echo "  ls -lh ~/.local/share/iss-wallpaper/loops/"
echo ""
