#!/bin/bash
# Uninstall ISS Live Wallpaper
# Stops services, removes binaries, LaunchAgents, and cached data.
set -euo pipefail

UID_NUM=$(id -u)

echo "ISS Live Wallpaper — Uninstall"
echo "================================"
echo ""

# --- Stop LaunchAgents ---
echo "Stopping services..."
launchctl bootout "gui/$UID_NUM/com.simonlowes.iss-video-wallpaper" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM/com.simonlowes.iss-capture-loop" 2>/dev/null || true
echo "  Services stopped"

# --- Remove LaunchAgent plists ---
echo "Removing LaunchAgents..."
rm -f "$HOME/Library/LaunchAgents/com.simonlowes.iss-video-wallpaper.plist"
rm -f "$HOME/Library/LaunchAgents/com.simonlowes.iss-capture-loop.plist"
echo "  LaunchAgents removed"

# --- Remove binaries ---
echo "Removing binaries..."
rm -f "$HOME/.local/bin/iss-video-wallpaper"
rm -f "$HOME/.local/bin/iss-capture-loop.sh"
rm -f "$HOME/.local/bin/iss-wallpaper.sh"  # old static-frame script
echo "  Binaries removed"

# --- Remove cached data ---
echo "Removing cached data..."
rm -rf "$HOME/.local/share/iss-wallpaper"
echo "  Cache removed"

echo ""
echo "Uninstalled. Your desktop wallpaper will revert to whatever"
echo "macOS had set before the video overlay."
echo ""
echo "Dependencies (ffmpeg, yt-dlp, desktoppr) were NOT removed."
echo "To remove them: brew uninstall ffmpeg yt-dlp desktoppr"
echo ""
