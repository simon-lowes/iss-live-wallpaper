#!/bin/bash
# Captures a 30-second video loop from the NASA ISS live stream.
# Writes alternating loop_a.mp4 / loop_b.mp4 for the video wallpaper app
# to crossfade between. Includes brightness pre-check to skip night passes.

set -euo pipefail

# --- Config ---
YOUTUBE_ID="aB1yRz0HhdY"
CACHE_DIR="${HOME}/.local/share/iss-wallpaper"
LOOP_DIR="${CACHE_DIR}/loops"
STREAM_URL_CACHE="${CACHE_DIR}/stream_url"
TOGGLE_FILE="${CACHE_DIR}/.loop_toggle"
LOG_FILE="${CACHE_DIR}/iss-wallpaper.log"
LOOP_DURATION=30
BRIGHTNESS_THRESHOLD=20
MAX_URL_AGE=18000  # 5 hours

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
mkdir -p "$LOOP_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [capture] $1" >> "$LOG_FILE"
    # Trim log if it gets long
    local lines
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$lines" -gt 1000 ]; then
        tail -500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

# --- Stream URL (cached ~5 hours) ---
get_stream_url() {
    if [ -f "$STREAM_URL_CACHE" ]; then
        local age=$(( $(date +%s) - $(stat -f %m "$STREAM_URL_CACHE") ))
        if [ "$age" -lt "$MAX_URL_AGE" ]; then
            cat "$STREAM_URL_CACHE"
            return 0
        fi
    fi

    local url
    url=$(yt-dlp -f "best[height<=1080]" -g \
        "https://www.youtube.com/watch?v=${YOUTUBE_ID}" 2>/dev/null | head -1)
    if [ -n "$url" ]; then
        echo "$url" > "$STREAM_URL_CACHE"
        log "INFO: Refreshed stream URL"
        echo "$url"
        return 0
    fi
    return 1
}

# --- Brightness pre-check (single frame, ~2s) ---
is_bright() {
    local stream_url="$1"
    local brightness
    brightness=$(ffmpeg -i "$stream_url" -vframes 1 -vf "scale=1:1" -pix_fmt gray \
        -f rawvideo -v quiet - 2>/dev/null | od -An -tu1 | tr -d ' ')

    if [ -z "$brightness" ]; then
        return 0  # Can't measure — try anyway
    fi

    log "INFO: Brightness pre-check: ${brightness}/255"
    [ "$brightness" -gt "$BRIGHTNESS_THRESHOLD" ]
}

# --- Capture 30s loop ---
capture() {
    local stream_url="$1"
    local output="$2"
    local temp="${output}.tmp.mp4"

    # Try hardware encoding first (VideoToolbox), fall back to software
    if ffmpeg -i "$stream_url" \
        -t "$LOOP_DURATION" \
        -c:v h264_videotoolbox -b:v 2M \
        -an -movflags +faststart \
        "$temp" -y 2>/dev/null; then
        mv "$temp" "$output"
        return 0
    fi

    log "WARN: VideoToolbox failed, falling back to software encoding"

    if ffmpeg -i "$stream_url" \
        -t "$LOOP_DURATION" \
        -c:v libx264 -crf 28 -preset fast \
        -an -movflags +faststart \
        "$temp" -y 2>/dev/null; then
        mv "$temp" "$output"
        return 0
    fi

    rm -f "$temp"
    return 1
}

# --- Main ---
main() {
    local stream_url
    stream_url=$(get_stream_url) || {
        rm -f "$STREAM_URL_CACHE"
        log "ERROR: Failed to get stream URL"
        exit 1
    }

    # Skip capture during night passes
    if ! is_bright "$stream_url"; then
        log "SKIP: Dark frame (night pass), keeping current loop"
        exit 0
    fi

    # A/B alternation
    local target
    if [ -f "$TOGGLE_FILE" ]; then
        target="${LOOP_DIR}/loop_a.mp4"
        rm -f "$TOGGLE_FILE"
    else
        target="${LOOP_DIR}/loop_b.mp4"
        touch "$TOGGLE_FILE"
    fi

    if capture "$stream_url" "$target"; then
        local size
        size=$(stat -f %z "$target" 2>/dev/null || echo "?")
        local mb=$(echo "scale=1; $size / 1048576" | bc 2>/dev/null || echo "?")
        log "OK: Captured ${LOOP_DURATION}s → $(basename "$target") (${mb}MB)"
    else
        log "ERROR: Capture failed, invalidating URL cache"
        rm -f "$STREAM_URL_CACHE"
        exit 1
    fi
}

main
