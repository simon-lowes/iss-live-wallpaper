#!/bin/bash
# Shared state, logging and source-selection policy for the space wallpaper.
# Sourced by space-capture-loop.sh and space-watchdog.sh — never run directly.

# SPACE_DATA_DIR overrides the state location (used for isolated tests only).
DATA_DIR="${SPACE_DATA_DIR:-${HOME}/.local/share/space-wallpaper}"
LOOP_DIR="${DATA_DIR}/loops"
STATE_DIR="${DATA_DIR}/state"
FRAME_DIR="${DATA_DIR}/frames"
COOLDOWN_DIR="${STATE_DIR}/cooldown"
LOG_FILE="${DATA_DIR}/space-wallpaper.log"

CURRENT_FILE="${STATE_DIR}/current_source"
FAILCOUNT_FILE="${STATE_DIR}/fail_count"
ROTATION_FILE="${STATE_DIR}/last_rotation"
TOGGLE_FILE="${STATE_DIR}/loop_toggle"

# A source is dropped after this many consecutive capture failures (~3 min at
# a 45s capture interval), then sat out for COOLDOWN_SECS before being retried.
FAIL_THRESHOLD=4
COOLDOWN_SECS=3600
ROTATION_SECS=21600   # 6 hours

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
mkdir -p "$LOOP_DIR" "$STATE_DIR" "$FRAME_DIR" "$COOLDOWN_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1" >> "$LOG_FILE"
    local lines
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$lines" -gt 2000 ]; then
        tail -1000 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

now() { date +%s; }

# --- Portable timeout (macOS ships no coreutils `timeout`) ---
# Without this a stalled yt-dlp or ffmpeg keeps the LaunchAgent instance alive
# forever, so launchd never starts another run and the whole thing wedges
# silently. This was the 2026-05-30 freeze; do not remove it.
# Returns the command's exit code, or 124 if it was killed on timeout.
run_timeout() {
    local secs="$1"; shift
    "$@" &
    local cmd_pid=$!
    # The watcher's stdio goes to /dev/null: if it inherited a pipe, as in
    # x=$(run_timeout N cmd | ...), its orphaned `sleep` would hold the pipe
    # open and stall the caller for the full N seconds even when cmd exits fast.
    ( sleep "$secs"; kill -TERM "$cmd_pid" 2>/dev/null; sleep 3; kill -KILL "$cmd_pid" 2>/dev/null ) \
        </dev/null >/dev/null 2>&1 &
    local watch_pid=$!
    local rc=0
    wait "$cmd_pid" 2>/dev/null || rc=$?
    if kill -0 "$watch_pid" 2>/dev/null; then
        kill -TERM "$watch_pid" 2>/dev/null || true
        wait "$watch_pid" 2>/dev/null || true
    else
        rc=124
    fi
    return "$rc"
}

# --- Cooldown bookkeeping ---

in_cooldown() {
    local f="${COOLDOWN_DIR}/$1"
    [ -f "$f" ] || return 1
    local until; until=$(cat "$f" 2>/dev/null || echo 0)
    if [ "$(now)" -ge "$until" ]; then
        rm -f "$f"
        return 1
    fi
    return 0
}

start_cooldown() {
    echo "$(( $(now) + COOLDOWN_SECS ))" > "${COOLDOWN_DIR}/$1"
}

clear_all_cooldowns() {
    find "$COOLDOWN_DIR" -type f -delete 2>/dev/null || true
}

# --- Source selection policy ---
#
# pick_source <exclude_id> [avoid_kind]
#
# Chooses at random from sources that are not in cooldown, are not
# <exclude_id>, and — where possible — are not of kind <avoid_kind>.
#
# The avoid_kind preference is the point of the mixed pool. All three YouTube
# sources share one failure mode: yt-dlp breaking against a YouTube change
# kills every one of them at once. Stepping to a different kind after a
# youtube failure reaches a working wallpaper in a single hop, instead of
# cycling through three feeds that are all guaranteed to fail.
#
# Falls back, in order: preferred kind -> any kind -> clear all cooldowns and
# retry. The last step means the pool can never be exhausted into showing
# nothing.
pick_source() {
    local exclude="${1:-}" avoid_kind="${2:-}"
    local preferred=() any=()

    local s
    for s in "${SOURCES[@]}"; do
        [ "$s" = "$exclude" ] && continue
        in_cooldown "$s" && continue
        any+=("$s")
        if [ -n "$avoid_kind" ] && [ "$(kind_of "$s")" != "$avoid_kind" ]; then
            preferred+=("$s")
        fi
    done

    local pool=()
    if [ ${#preferred[@]} -gt 0 ]; then
        pool=("${preferred[@]}")
    elif [ ${#any[@]} -gt 0 ]; then
        pool=("${any[@]}")
    else
        # Everything is cooling down. Rather than show nothing, forgive all
        # sources and try again from a clean slate.
        clear_all_cooldowns
        for s in "${SOURCES[@]}"; do
            [ "$s" = "$exclude" ] || pool+=("$s")
        done
        [ ${#pool[@]} -eq 0 ] && pool=("${SOURCES[@]}")
    fi

    echo "${pool[$((RANDOM % ${#pool[@]}))]}"
}

current_source() {
    local id=""
    [ -f "$CURRENT_FILE" ] && id=$(cat "$CURRENT_FILE" 2>/dev/null)
    if [ -z "$id" ] || ! source_def "$id" >/dev/null 2>&1; then
        id=$(pick_source "")
        set_source "$id"
    fi
    echo "$id"
}

set_source() {
    echo "$1" > "$CURRENT_FILE"
    echo 0 > "$FAILCOUNT_FILE"
    echo "$(now)" > "$ROTATION_FILE"
}

# Restart the renderer so it can never sit on a stale frame after a switch.
kick_renderer() {
    launchctl kickstart -k "gui/$(id -u)/com.simonlowes.space-video-wallpaper" 2>/dev/null || true
}

switch_source() {
    local reason="$1" exclude="$2" avoid_kind="${3:-}"
    local next; next=$(pick_source "$exclude" "$avoid_kind")
    source_def "$next" >/dev/null 2>&1
    set_source "$next"
    log "SWITCH: ${reason} → ${next} (${SRC_NAME})"
    kick_renderer
}
