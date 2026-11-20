#!/bin/bash
# Health check and rotation for the space wallpaper. Runs every 15 minutes.
#
# Three jobs, in order:
#   1. renderer health  — restart a dead or long-running renderer
#   2. stall detection  — force a failover if loops have stopped advancing
#   3. rotation         — move to a random new source every ROTATION_SECS
#
# Fast failover on a broken feed is handled in space-capture-loop.sh (within
# ~3 min); this is the slower net that catches what per-capture logic can't see.

set -euo pipefail

LOG_TAG="watchdog"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=space-sources.conf
source "${SELF_DIR}/space-sources.conf"
# shellcheck source=space-common.sh
source "${SELF_DIR}/space-common.sh"

RENDERER_BIN="${HOME}/.local/bin/space-video-wallpaper"
# Bound renderer uptime. The old build sat frozen for six weeks while capture
# kept writing fresh loops behind it; a daily restart caps that exposure at 24h
# regardless of which internal stall caused it.
MAX_RENDERER_UPTIME=86400
# Long enough to sit through a full ISS night pass (~45 min) without a false
# positive, short enough to catch a genuinely wedged capture.
MAX_LOOP_AGE=3600

renderer_pid() {
    pgrep -f "^${RENDERER_BIN}$" 2>/dev/null | head -1
}

# macOS ps has no `etimes` (seconds elapsed) — that is a GNU extension, and
# asking for it makes BSD ps dump its keyword list instead of a number. Parse
# `etime` instead, which is [[DD-]HH:]MM:SS. 10# forces base 10 so that
# zero-padded values like 08 are not read as invalid octal.
proc_uptime_secs() {
    local e; e=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')
    [ -z "$e" ] && return 1
    local days=0 rest="$e" h=0 m=0 s=0
    case "$e" in *-*) days="${e%%-*}"; rest="${e#*-}" ;; esac
    case "$rest" in
        *:*:*) IFS=: read -r h m s <<< "$rest" ;;
        *:*)   IFS=: read -r m s <<< "$rest" ;;
        *)     s="$rest" ;;
    esac
    echo $(( 10#$days * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

check_renderer() {
    # `|| true` matters: "not running" is the case this function exists to
    # handle, but pgrep exits non-zero on no match and set -e would abort here.
    local pid; pid=$(renderer_pid || true)

    if [ -z "$pid" ]; then
        log "RENDERER: not running, kickstarting"
        kick_renderer
        return
    fi

    local uptime; uptime=$(proc_uptime_secs "$pid" || true)
    [ -z "$uptime" ] && return

    if [ "$uptime" -ge "$MAX_RENDERER_UPTIME" ]; then
        log "RENDERER: uptime ${uptime}s ≥ ${MAX_RENDERER_UPTIME}s, recycling"
        kick_renderer
    fi
}

newest_loop_age() {
    local newest
    newest=$(ls -t "${LOOP_DIR}"/loop_*.mp4 2>/dev/null | head -1 || true)
    [ -z "$newest" ] && { echo 999999; return; }
    echo $(( $(now) - $(stat -f %m "$newest") ))
}

check_stalled() {
    local age; age=$(newest_loop_age)
    [ "$age" -lt "$MAX_LOOP_AGE" ] && return

    local id; id=$(current_source)
    source_def "$id" >/dev/null 2>&1 || return
    log "STALL: no fresh loop for ${age}s on ${id}"
    start_cooldown "$id"
    switch_source "stalled ${age}s" "$id" "$SRC_KIND"
}

check_rotation() {
    local last=0
    [ -f "$ROTATION_FILE" ] && last=$(cat "$ROTATION_FILE" 2>/dev/null || echo 0)
    local elapsed=$(( $(now) - last ))
    [ "$elapsed" -lt "$ROTATION_SECS" ] && return

    local id; id=$(current_source)
    # No avoid_kind here: this is a healthy scheduled rotation, so every kind
    # is fair game and variety is the whole point.
    switch_source "scheduled rotation after ${elapsed}s" "$id" ""
}

main() {
    check_renderer
    check_stalled
    check_rotation
}

main
