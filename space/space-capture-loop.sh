#!/bin/bash
# Captures one video loop from the currently selected space feed and writes it
# to loop_a.mp4 / loop_b.mp4 alternately, for the renderer to crossfade between.
#
# Two backends:
#   youtube  live ISS video, via yt-dlp + ffmpeg (with a night-pass skip)
#   imgseq   satellite stills over plain HTTPS, assembled into a timelapse
#
# Runs every 45s from launchd. Owns capture only; source-selection policy lives
# in space-common.sh, except that a source failing FAIL_THRESHOLD times in a row
# triggers an immediate failover here rather than waiting for the watchdog.

set -euo pipefail

LOG_TAG="capture"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=space-sources.conf
source "${SELF_DIR}/space-sources.conf"
# shellcheck source=space-common.sh
source "${SELF_DIR}/space-common.sh"

LOOP_DURATION=30
BRIGHTNESS_THRESHOLD=20
MAX_URL_AGE=18000        # re-resolve a YouTube stream URL after 5 hours
MAX_NEW_FRAMES_PER_RUN=6 # bound per-cycle work so a cold start can't overrun
MIN_FRAMES_TO_BUILD=10   # don't show a stuttery 3-frame loop on first run

# Padded to 16:9. Full-disk satellite images are square, and the renderer uses
# .resizeAspectFill — without padding it would scale the square to screen width
# and crop the top and bottom of Earth clean off. Padding to 16:9 means that on
# any screen 16:9 or narrower (16:10, 3:2) only the black side bars get cropped.
PAD_W=1920
PAD_H=1080
DISK_H=1000              # leaves a small margin around the disk

# ---------------------------------------------------------------- youtube ---

get_stream_url() {
    local id="$1" cache="${STATE_DIR}/stream_url_${SRC_ID}"
    if [ -f "$cache" ]; then
        local age=$(( $(now) - $(stat -f %m "$cache") ))
        if [ "$age" -lt "$MAX_URL_AGE" ]; then
            cat "$cache"
            return 0
        fi
    fi

    # YouTube serves these live streams as separate video-only and audio-only
    # HLS formats, so a combined "best" selector finds nothing. Only picture is
    # needed: take the best video-only format, falling back to a combined one.
    # -g prints one manifest URL per selected format; this selector picks one.
    # Bounded by run_timeout like every other network call (see space-common.sh).
    local url err="${STATE_DIR}/yt-dlp.err"
    url=$(run_timeout 60 yt-dlp --no-warnings -f "bv*[height<=1080]/b[height<=1080]" -g \
        "https://www.youtube.com/watch?v=${id}" 2>"$err" | head -1) || url=""
    if [ -n "$url" ]; then
        echo "$url" > "$cache"
        log "INFO: refreshed stream URL for ${SRC_ID}"
        echo "$url"
        return 0
    fi
    log "WARN: ${SRC_ID}: yt-dlp: $(grep -m1 'ERROR' "$err" 2>/dev/null | cut -c1-200 || true)"
    return 1
}

# ISS night passes are dark; sample one pixel and skip rather than show black.
is_bright() {
    local brightness
    brightness=$(run_timeout 30 ffmpeg -i "$1" -vframes 1 -vf "scale=1:1" -pix_fmt gray \
        -f rawvideo -v quiet - 2>/dev/null | od -An -tu1 | tr -d ' ') || brightness=""
    [ -z "$brightness" ] && return 0   # can't measure — try anyway
    log "INFO: brightness ${brightness}/255"
    [ "$brightness" -gt "$BRIGHTNESS_THRESHOLD" ]
}

encode_stream() {
    local url="$1" out="$2" tmp="${2}.tmp.mp4"
    if run_timeout 90 ffmpeg -i "$url" -t "$LOOP_DURATION" \
        -c:v h264_videotoolbox -b:v 2M -an -movflags +faststart "$tmp" -y 2>/dev/null; then
        mv "$tmp" "$out"; return 0
    fi
    log "WARN: VideoToolbox failed, falling back to software encoding"
    if run_timeout 90 ffmpeg -i "$url" -t "$LOOP_DURATION" \
        -c:v libx264 -crf 28 -preset fast -an -movflags +faststart "$tmp" -y 2>/dev/null; then
        mv "$tmp" "$out"; return 0
    fi
    rm -f "$tmp"; return 1
}

capture_youtube() {
    local url
    url=$(get_stream_url "$SRC_YTID") || {
        rm -f "${STATE_DIR}/stream_url_${SRC_ID}"
        log "ERROR: ${SRC_ID}: could not resolve stream URL"
        return 1
    }

    if ! is_bright "$url"; then
        log "SKIP: ${SRC_ID}: night pass, keeping current loop"
        return 2   # not a failure
    fi

    if encode_stream "$url" "$(next_loop_target)"; then
        return 0
    fi
    rm -f "${STATE_DIR}/stream_url_${SRC_ID}"
    log "ERROR: ${SRC_ID}: capture failed, invalidated URL cache"
    return 1
}

# ----------------------------------------------------------------- imgseq ---

# NOAA bakes a caption bar across the bottom and a NOAA roundel into the
# bottom-left of every GOES frame. Both sit outside the disk, so they can be
# masked out. Coordinates are for the 1808x1808 product specifically.
GOES_DEBRAND="drawbox=x=0:y=1758:w=1808:h=50:color=black:t=fill,drawbox=x=0:y=1560:w=225:h=250:color=black:t=fill,"

# NOAA's deep-space background is a very dark grey, not true black. Padded into
# a pure-black 16:9 frame that leaves a faint rectangle outlined around Earth,
# and makes the masks above show as darker patches. Crushing everything below
# 20/255 to true black removes both. Verified against a night frame: city
# lights, clouds and coastlines all sit well above the threshold and survive.
BLACK_CRUSH="lutrgb=r='if(lt(val,20),0,val)':g='if(lt(val,20),0,val)':b='if(lt(val,20),0,val)',"

# Download one image and normalise it straight to a padded 1920x1080 JPEG.
# Normalising at ingest rather than at build time keeps the frame cache at
# ~200KB per frame instead of ~2.2MB, and makes the video build a plain
# numbered-sequence read with no filtering.
# $3 is an optional filter chain applied first; it must end with a comma.
ingest_frame() {
    local url="$1" dest="$2" pre="${3:-}" raw="${2}.raw"
    curl -sS -L --max-time 60 -o "$raw" "$url" 2>/dev/null || { rm -f "$raw"; return 1; }
    [ -s "$raw" ] || { rm -f "$raw"; return 1; }
    if run_timeout 60 ffmpeg -i "$raw" \
        -vf "${pre}${BLACK_CRUSH}scale=-2:${DISK_H},pad=${PAD_W}:${PAD_H}:(ow-iw)/2:(oh-ih)/2:black" \
        -q:v 3 "${dest}.tmp.jpg" -y 2>/dev/null; then
        mv "${dest}.tmp.jpg" "$dest"; rm -f "$raw"; return 0
    fi
    rm -f "$raw" "${dest}.tmp.jpg"; return 1
}

# NOAA STAR publishes a browsable directory of timestamped full-disk frames.
fetch_goes() {
    local sat="$SRC_ARG" dir="$1"
    local base="https://cdn.star.nesdis.noaa.gov/${sat}/ABI/FD/GEOCOLOR"
    local names
    names=$(curl -sS --max-time 60 "${base}/" 2>/dev/null \
        | grep -oE "[0-9]{11}_${sat}-ABI-FD-GEOCOLOR-1808x1808\.jpg" \
        | sort -u | tail -n "$SRC_FRAMES") || return 1
    [ -z "$names" ] && return 1

    # Newest first, so a cold start shows the last couple of hours rather than
    # spending several cycles working forward from a 10-hour-old frame. The
    # build step sorts by key regardless, so playback order is unaffected.
    local added=0 n key
    for n in $(echo "$names" | sort -r); do
        [ "$added" -ge "$MAX_NEW_FRAMES_PER_RUN" ] && break
        key="${n%%_*}"
        [ -f "${dir}/${key}.jpg" ] && continue
        if ingest_frame "${base}/${n}" "${dir}/${key}.jpg" "$GOES_DEBRAND"; then
            added=$((added + 1))
        fi
    done
    log "INFO: ${SRC_ID}: ${added} new frame(s)"
    return 0
}

# NICT publishes Himawari on a fixed 10-minute UTC grid with no listing, as a
# tile grid. "2d" is 2x2 tiles of 550px, stitched here into 1100x1100.
fetch_himawari() {
    local dir="$1" zoom="$SRC_ARG"
    local base="https://himawari8.nict.go.jp/img/D531106/${zoom}/550"
    local stamps
    stamps=$(python3 -c "
import datetime
# NICT lags roughly 20-30 min behind real time; start 40 min back to be safe.
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=40)
t = t.replace(minute=(t.minute // 10) * 10, second=0, microsecond=0)
for i in range($SRC_FRAMES):
    print((t - datetime.timedelta(minutes=10 * i)).strftime('%Y%m%d%H%M'))
") || return 1

    local added=0 s key y m d hm
    for s in $stamps; do
        [ "$added" -ge "$MAX_NEW_FRAMES_PER_RUN" ] && break
        key="$s"
        [ -f "${dir}/${key}.jpg" ] && continue
        y="${s:0:4}"; m="${s:4:2}"; d="${s:6:2}"; hm="${s:8:4}"
        local p="${base}/${y}/${m}/${d}/${hm}00"
        local t00="${dir}/.t00.png" t10="${dir}/.t10.png"
        local t01="${dir}/.t01.png" t11="${dir}/.t11.png"
        if curl -sS -L --max-time 40 -o "$t00" "${p}_0_0.png" 2>/dev/null \
        && curl -sS -L --max-time 40 -o "$t10" "${p}_1_0.png" 2>/dev/null \
        && curl -sS -L --max-time 40 -o "$t01" "${p}_0_1.png" 2>/dev/null \
        && curl -sS -L --max-time 40 -o "$t11" "${p}_1_1.png" 2>/dev/null \
        && [ -s "$t00" ] && [ -s "$t11" ]; then
            if run_timeout 60 ffmpeg -i "$t00" -i "$t10" -i "$t01" -i "$t11" \
                -filter_complex "[0][1]hstack[top];[2][3]hstack[bot];[top][bot]vstack,${BLACK_CRUSH}scale=-2:${DISK_H},pad=${PAD_W}:${PAD_H}:(ow-iw)/2:(oh-ih)/2:black" \
                -q:v 3 "${dir}/${key}.jpg.tmp.jpg" -y 2>/dev/null; then
                mv "${dir}/${key}.jpg.tmp.jpg" "${dir}/${key}.jpg"
                added=$((added + 1))
            fi
        fi
        rm -f "$t00" "$t10" "$t01" "$t11" "${dir}/${key}.jpg.tmp.jpg"
    done
    log "INFO: ${SRC_ID}: ${added} new frame(s)"
    return 0
}

# DSCOVR EPIC sits at L1 and sees the whole sunlit disk. Its archive runs 1-3
# days behind, so this is a recent Earth rotation rather than a live view.
fetch_epic() {
    local dir="$1" kindarg="$SRC_ARG"
    local meta
    meta=$(curl -sS --max-time 60 "https://epic.gsfc.nasa.gov/api/${kindarg}" 2>/dev/null \
        | python3 -c "
import sys, json
d = json.load(sys.stdin)
for f in d:
    y, m, dd = f['date'][:10].split('-')
    print(f['image'], f'https://epic.gsfc.nasa.gov/archive/${kindarg}/{y}/{m}/{dd}/png/{f[\"image\"]}.png')
") || return 1
    [ -z "$meta" ] && return 1

    local added=0
    while read -r key url; do
        [ -z "$key" ] && continue
        [ "$added" -ge "$MAX_NEW_FRAMES_PER_RUN" ] && break
        [ -f "${dir}/${key}.jpg" ] && continue
        if ingest_frame "$url" "${dir}/${key}.jpg"; then
            added=$((added + 1))
        fi
    done <<< "$meta"
    log "INFO: ${SRC_ID}: ${added} new frame(s)"
    return 0
}

# Assemble the newest SRC_FRAMES cached frames into a loop.
build_timelapse() {
    local dir="$1"
    local keys count newest built_marker="${STATE_DIR}/last_built_${SRC_ID}"

    keys=$(find "$dir" -name '*.jpg' -type f 2>/dev/null | sort | tail -n "$SRC_FRAMES")
    count=$(echo "$keys" | grep -c . || true)
    if [ "$count" -lt "$MIN_FRAMES_TO_BUILD" ]; then
        log "WAIT: ${SRC_ID}: ${count}/${MIN_FRAMES_TO_BUILD} frames cached, not building yet"
        return 2
    fi

    newest=$(basename "$(echo "$keys" | tail -1)")
    if [ -f "$built_marker" ] && [ "$(cat "$built_marker")" = "$newest" ]; then
        return 2   # nothing new since last build — not a failure
    fi

    local build="${dir}/.build"
    rm -rf "$build" 2>/dev/null || true
    mkdir -p "$build"
    local i=0 f
    while read -r f; do
        [ -z "$f" ] && continue
        ln -sf "$f" "$(printf '%s/f%04d.jpg' "$build" "$i")"
        i=$((i + 1))
    done <<< "$keys"

    local out; out=$(next_loop_target)
    local tmp="${out}.tmp.mp4"
    if run_timeout 120 ffmpeg -framerate "$SRC_FPS" -i "${build}/f%04d.jpg" \
        -c:v h264_videotoolbox -b:v 6M -pix_fmt yuv420p \
        -an -movflags +faststart "$tmp" -y 2>/dev/null \
    || run_timeout 180 ffmpeg -framerate "$SRC_FPS" -i "${build}/f%04d.jpg" \
        -c:v libx264 -crf 22 -preset fast -pix_fmt yuv420p \
        -an -movflags +faststart "$tmp" -y 2>/dev/null; then
        mv "$tmp" "$out"
        echo "$newest" > "$built_marker"
        rm -rf "$build"
        return 0
    fi
    rm -f "$tmp"; rm -rf "$build"
    return 1
}

# Keep twice the loop length so a rebuild always has a full window available.
prune_frames() {
    local dir="$1" keep=$(( SRC_FRAMES * 2 ))
    local total; total=$(find "$dir" -name '*.jpg' -type f 2>/dev/null | wc -l | tr -d ' ')
    [ "$total" -le "$keep" ] && return 0
    find "$dir" -name '*.jpg' -type f 2>/dev/null | sort | head -n $(( total - keep )) \
        | while read -r f; do rm -f "$f"; done
}

capture_imgseq() {
    local dir="${FRAME_DIR}/${SRC_ID}"
    mkdir -p "$dir"

    case "$SRC_PROTO" in
        goes)     fetch_goes     "$dir" || { log "ERROR: ${SRC_ID}: fetch failed"; return 1; } ;;
        himawari) fetch_himawari "$dir" || { log "ERROR: ${SRC_ID}: fetch failed"; return 1; } ;;
        epic)     fetch_epic     "$dir" || { log "ERROR: ${SRC_ID}: fetch failed"; return 1; } ;;
        *) log "ERROR: ${SRC_ID}: unknown imgseq protocol '${SRC_PROTO}'"; return 1 ;;
    esac

    prune_frames "$dir"
    build_timelapse "$dir"
}

# ------------------------------------------------------------------- main ---

# Alternate between loop_a and loop_b so the renderer has an old and a new file
# to crossfade between.
next_loop_target() {
    if [ -f "$TOGGLE_FILE" ]; then
        rm -f "$TOGGLE_FILE"; echo "${LOOP_DIR}/loop_a.mp4"
    else
        touch "$TOGGLE_FILE"; echo "${LOOP_DIR}/loop_b.mp4"
    fi
}

record_success() {
    echo 0 > "$FAILCOUNT_FILE"
}

record_failure() {
    local n=1
    [ -f "$FAILCOUNT_FILE" ] && n=$(( $(cat "$FAILCOUNT_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FAILCOUNT_FILE"
    log "WARN: ${SRC_ID}: consecutive failures ${n}/${FAIL_THRESHOLD}"
    if [ "$n" -ge "$FAIL_THRESHOLD" ]; then
        start_cooldown "$SRC_ID"
        # Prefer a different kind: a yt-dlp breakage takes out every youtube
        # source at once, so stepping sideways within that kind is pointless.
        switch_source "${SRC_ID} failed ${n}x" "$SRC_ID" "$SRC_KIND"
    fi
}

main() {
    rm -f "${LOOP_DIR}"/*.tmp.mp4 2>/dev/null || true

    SRC_ID=$(current_source)
    source_def "$SRC_ID" || { log "ERROR: unknown source '${SRC_ID}'"; exit 1; }

    local rc=0
    case "$SRC_KIND" in
        youtube) capture_youtube || rc=$? ;;
        imgseq)  capture_imgseq  || rc=$? ;;
        *) log "ERROR: unknown kind '${SRC_KIND}'"; exit 1 ;;
    esac

    case "$rc" in
        0)
            record_success
            local target size mb
            target=$(ls -t "${LOOP_DIR}"/loop_*.mp4 2>/dev/null | head -1 || true)
            size=$(stat -f %z "$target" 2>/dev/null || echo 0)
            mb=$(echo "scale=1; $size / 1048576" | bc 2>/dev/null || echo "?")
            log "OK: ${SRC_ID} (${SRC_NAME}) → $(basename "$target") (${mb}MB)"
            ;;
        2) : ;;   # deliberate skip (night pass, or no new frames) — not a failure
        *) record_failure ;;
    esac
}

main
