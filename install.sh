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
mkdir -p "$BIN_DIR" "$DATA_DIR/loops"

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
launchctl bootout "gui/$UID_NUM/com.simonlowes.iss-video-wallpaper" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM/com.simonlowes.iss-capture-loop" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$UID_NUM" "$AGENT_DIR/com.simonlowes.iss-video-wallpaper.plist"
launchctl bootstrap "gui/$UID_NUM" "$AGENT_DIR/com.simonlowes.iss-capture-loop.plist"

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
