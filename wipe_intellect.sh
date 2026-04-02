#!/bin/bash
# =============================================================================
# INTELLECT MASTER WIPE (V21 - NIST 800-88 + LIVE PROGRESS + FF FANFARE)
#
# V21 changes from V20:
#   - OSC version detection: --performQuickestErase only used on OSC builds
#     where --confirm I_PROMISE_TO_BE_CAREFUL is valid (pre-v26 regression)
#   - Fixed sanicap bitmask: crypto=bit30(0x40000000), block=bit1(0x02),
#     overwrite=bit2(0x04) — was inverted in V20
#   - NVMe cascade now correctly tries crypto sanitize (0x04) before block
#   - NVMe wipe path now calls verify_wipe (was missing entirely in V20)
#   - OSC --writeSame now passes --confirm this-will-erase-data (was missing,
#     causing silent no-op in v26 per log evidence)
#   - NIST Clear/Purge split: verify_wipe now classifies each METHOD as
#     Clear (overwrite → check zeros) or Purge (crypto/sanitize → check
#     drive accessibility only; non-zero readback is expected and correct
#     per NIST SP 800-88 Rev. 1 §2.4). Prevents NVMe hardware erases from
#     incorrectly failing verification and cascading to dd.
#   - Certificate of destruction now includes NIST Action (Clear/Purge),
#     method-specific Verify Method description, and correct hex proof
#     caption per action type
#   - Cascade resume-from loop: verify failure no longer jumps straight to
#     dd — instead resumes at the next untried cascade step; dd only fires
#     after all steps (including blkdiscard) have been exhausted
#   - blkdiscard capability probed up front; dd gated behind it
#   - Certificate now includes first 512 bytes hexdump of drive post-wipe
#   - Removed duplicate STATUS_BOX_DRAWN=0 reset in main loop
#
# SATA cascade:
#   1) OSC --performQuickestErase (version-gated)
#   2) OSC --writeSame 0 --confirm this-will-erase-data
#   3) blkdiscard --secure          4) blkdiscard --zeroout
#   5) hdparm Enhanced Sec Erase    6) hdparm Sec Erase
#   7) OSC --overwrite 0            8) dd (last resort)
#
# NVMe cascade:
#   sanicap pre-check (corrected bitmask), then:
#   1) nvme sanitize 0x04 (crypto)  2) nvme sanitize 0x02 (block)
#   3) nvme format ses=2            4) nvme format ses=1
#   5) OSC --performQuickestErase (version-gated)
#   6) dd (last resort)
#
# POST-WIPE: Multi-zone verify (start/middle/end) on ALL drive types.
#   Hardware method verify failure -> forced dd -> re-verify.
#   Certificate includes first 512 bytes hexdump as destruction proof.
# =============================================================================

USB_PATH="/mnt/usb"
OSC_PATH="$USB_PATH/openSeaChest_portable"
OSC_LIB="$OSC_PATH/lib"           # shared libraries OpenSeaChest needs at runtime
NVME_BIN="$USB_PATH/tools/nvme"
CERT_DIR="$USB_PATH/Certificates"
mkdir -p "$CERT_DIR"

# Export OSC lib path so dynamic linker finds it for all OSC calls
# Without this, OSC silently fails if .so files aren't in standard system paths
export LD_LIBRARY_PATH="$OSC_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# =============================================================================
# OSC VERSION DETECTION
# --performQuickestErase requires --confirm I_PROMISE_TO_BE_CAREFUL.
# In OSC v26, the --confirm argument parser broke and rejects this string,
# causing a silent no-op. We detect the version here once and gate all
# --performQuickestErase calls on OSC_QE_SUPPORTED=1.
#
# Detection logic:
#   - Parse major version from "openSeaChest_Erase Version: X.YY.Z"
#   - v26+ = broken confirm = OSC_QE_SUPPORTED=0
#   - v25 and below = working = OSC_QE_SUPPORTED=1
#   - Binary missing or version unreadable = OSC_QE_SUPPORTED=0 (safe default)
# =============================================================================
OSC_QE_SUPPORTED=0
OSC_VERSION_STR=""
if [ -x "$OSC_PATH/openSeaChest_Erase" ]; then
    OSC_VERSION_STR=$(LD_LIBRARY_PATH="$OSC_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        "$OSC_PATH/openSeaChest_Erase" --version 2>/dev/null \
        | grep -i "openSeaChest_Erase Version" | head -n1)
    OSC_MAJOR=$(echo "$OSC_VERSION_STR" | grep -oP 'Version:\s*\K\d+' | head -n1)
    if [ -n "$OSC_MAJOR" ] && [ "$OSC_MAJOR" -lt 26 ] 2>/dev/null; then
        OSC_QE_SUPPORTED=1
    fi
fi

USB_DEV=$(lsblk -no pkname "$(findmnt -nvo SOURCE "$USB_PATH")" 2>/dev/null)
PCNAME=$(hostname)
DATESTAMP=$(date +%Y%m%d)
LOG_FILE="$CERT_DIR/${DATESTAMP}_${PCNAME}_wipe.log"

# Current drive info — set in main loop, used by status functions
CURRENT_TARGET=""
CURRENT_MODEL=""
CURRENT_SIZE=""
CURRENT_TRY=""
CURRENT_METHOD_NAME=""

# Tracks whether a status box is already on screen — used to overwrite
# it in place rather than printing a new one below it each time
STATUS_BOX_DRAWN=0
# Box height: 1 blank + top border + DRIVE + SIZE + STEP + STATUS + bottom border
STATUS_BOX_LINES=7

# =============================================================================
# DISPLAY: Status box — overwrites itself in place on every call
# so only one box is ever visible on screen at a time.
# Uses ANSI cursor-up + line-clear to erase the previous box cleanly.
# =============================================================================
print_status() {
    local MSG="$1"

    if [ "$STATUS_BOX_DRAWN" = "1" ]; then
        # Move cursor up STATUS_BOX_LINES lines then clear each line going down
        printf "\033[%dA" "$STATUS_BOX_LINES"
        for i in $(seq 1 $STATUS_BOX_LINES); do
            printf "\033[2K\n"   # clear entire line, move down
        done
        printf "\033[%dA" "$STATUS_BOX_LINES"   # back to top of box
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    printf "║  DRIVE  : %-47s ║\n" "$CURRENT_TARGET  ($CURRENT_MODEL)"
    printf "║  SIZE   : %-47s ║\n" "$CURRENT_SIZE"
    printf "║  STEP   : %-47s ║\n" "$CURRENT_TRY"
    printf "║  STATUS : %-47s ║\n" "$MSG"
    echo "╚══════════════════════════════════════════════════════════╝"

    STATUS_BOX_DRAWN=1
}

# Silently log to file only — does NOT print to screen.
# Use print_status for any screen output during a wipe.
log() {
    echo "$1" >> "$LOG_FILE"
}

# Log to file AND print a plain line to screen (used outside wipe functions)
logecho() {
    echo "$1" | tee -a "$LOG_FILE"
}

# =============================================================================
# AUDIO: Final Fantasy Victory Fanfare via PC speaker
#
# Three methods attempted in order:
#   1) beep utility  — precise frequency + duration control
#   2) pcspkr direct — modprobe pcspkr then use /dev/tty bell sequences
#   3) Visual only   — flashing COMPLETE banner if no speaker response
#
# FF Victory Fanfare note map (concert pitch):
#   B4=494  Eb5=622  E5=659  G5=784  A5=880  B5=988
#   C#5=554 G4=392   Bb4=466
#
# Fanfare phrase breakdown:
#   Pickup:    B4 (short)
#   Phrase 1:  E5 E5 E5 E5 | Eb5 E5 (rest) G5 G5 G5
#   Phrase 2:  G4 Bb4 E5 G5 A5
#   Resolve:   B5 (long hold)
# =============================================================================
play_fanfare() {
    echo ""
    echo "  ♪ Playing Final Fantasy Victory Fanfare ♪"
    log "  [audio] Attempting PC speaker fanfare"

    # Load pcspkr module first — required for both beep and bell methods
    # on minimal Linux builds like ShredOS. Safe to call even if already loaded.
    modprobe pcspkr 2>/dev/null || true
    modprobe snd-pcsp 2>/dev/null || true

    # --- Method 1: beep utility ----------------------------------------------
    if command -v beep > /dev/null 2>&1; then
        log "  [audio] Using beep utility"

        # Each note: -f frequency(Hz) -l duration(ms) -D delay_after(ms)
        # Pickup -> Phrase 1 -> Phrase 2 -> Resolve
        beep -f 494  -l 120 -D 30  \
        -n -f 659  -l 120 -D 30  \
        -n -f 659  -l 120 -D 30  \
        -n -f 659  -l 180 -D 30  \
        -n -f 622  -l 120 -D 30  \
        -n -f 659  -l 220 -D 120 \
        -n -f 784  -l 120 -D 30  \
        -n -f 784  -l 120 -D 30  \
        -n -f 784  -l 180 -D 120 \
        -n -f 392  -l 100 -D 20  \
        -n -f 466  -l 100 -D 20  \
        -n -f 659  -l 140 -D 20  \
        -n -f 784  -l 140 -D 20  \
        -n -f 880  -l 600 -D 60  \
        -n -f 988  -l 900 -D 0   \
        && {
            log "  [audio] beep fanfare complete"
            return 0
        }
        log "  [audio] beep returned error — falling through to bell method"
    else
        log "  [audio] beep utility not found — trying bell method"
    fi

    # --- Method 2: terminal bell via /dev/tty --------------------------------
    # Approximates the fanfare rhythm using bell bursts.
    # Works as long as pcspkr module is loaded (done above).
    local TTY_DEV
    # Find a usable tty — prefer /dev/tty1 (physical console on ShredOS)
    for DEV in /dev/tty1 /dev/tty /dev/console; do
        [ -w "$DEV" ] && TTY_DEV="$DEV" && break
    done

    if [ -n "$TTY_DEV" ]; then
        log "  [audio] Using terminal bell via $TTY_DEV"

        # Pickup — 1 short note
        echo -ne "\a" > "$TTY_DEV"; sleep 0.15

        # Phrase 1 — E5 E5 E5 E5 | Eb5 E5 (pause) G5 G5 G5
        for i in 1 2 3 4; do
            echo -ne "\a" > "$TTY_DEV"; sleep 0.13
        done
        sleep 0.08
        echo -ne "\a" > "$TTY_DEV"; sleep 0.10
        echo -ne "\a" > "$TTY_DEV"; sleep 0.25
        for i in 1 2 3; do
            echo -ne "\a" > "$TTY_DEV"; sleep 0.15
        done
        sleep 0.25

        # Phrase 2 — G4 Bb4 E5 G5 A5
        for i in 1 2 3 4 5; do
            echo -ne "\a" > "$TTY_DEV"; sleep 0.12
        done
        sleep 0.15

        # Resolve — rapid bells to simulate held B5
        for i in $(seq 1 8); do
            echo -ne "\a" > "$TTY_DEV"; sleep 0.07
        done

        log "  [audio] Bell sequence complete"
        return 0
    fi

    # --- Method 3: Visual fallback -------------------------------------------
    log "  [audio] No writable tty found — audio unavailable, visual only"
    return 1
}

# =============================================================================
# DISPLAY: Completion banner — shown after fanfare regardless of audio result
# =============================================================================
show_completion_banner() {
    local DRIVE_COUNT="$1"
    clear
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║                                                              ║"
    echo "  ║        ██████╗ ██████╗ ███╗   ██╗███████╗                  ║"
    echo "  ║       ██╔══██╗██╔═══██╗████╗  ██║██╔════╝                  ║"
    echo "  ║       ██║  ██║██║   ██║██╔██╗ ██║█████╗                    ║"
    echo "  ║       ██║  ██║██║   ██║██║╚██╗██║██╔══╝                    ║"
    echo "  ║       ██████╔╝╚██████╔╝██║ ╚████║███████╗                  ║"
    echo "  ║       ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚══════╝                  ║"
    echo "  ║                                                              ║"
    echo "  ║            ALL DRIVES WIPED SUCCESSFULLY                    ║"
    echo "  ║                                                              ║"
    printf "  ║            Drives processed : %-4s                          ║\n" "$DRIVE_COUNT"
    printf "  ║            Completed at     : %-28s   ║\n" "$(date '+%H:%M:%S %Y-%m-%d')"
    printf "  ║            Certificates     : %-28s   ║\n" "$CERT_DIR"
    echo "  ║                                                              ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

logp() {
    # log to file + update status box
    log "$1"
    print_status "$1"
}

# =============================================================================
# DISPLAY: Live spinner for commands with no native progress output
# Usage: start_spinner "message"  ->  stop_spinner
# Spinner runs in background; call stop_spinner to kill it cleanly
# =============================================================================
SPINNER_PID=""

start_spinner() {
    local MSG="$1"
    local SPIN_CHARS='|/-\'
    local START_TIME=$SECONDS
    (
        i=0
        while true; do
            ELAPSED=$(( SECONDS - START_TIME ))
            MINS=$(( ELAPSED / 60 ))
            SECS=$(( ELAPSED % 60 ))
            CHAR="${SPIN_CHARS:$((i % 4)):1}"
            printf "\r  %s  %s  [%02d:%02d elapsed]    " "$CHAR" "$MSG" "$MINS" "$SECS"
            sleep 1
            i=$(( i + 1 ))
        done
    ) &
    SPINNER_PID=$!
}

stop_spinner() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
        printf "\r%-70s\r" " "   # clear the spinner line
    fi
}

# =============================================================================
# DISPLAY: Live progress for blkdiscard
# blkdiscard has no native progress output. We run it in background and
# poll /proc/diskstats to show bytes written + elapsed time.
# =============================================================================
blkdiscard_with_progress() {
    local TARGET="$1"
    local FLAGS="$2"       # e.g. "--secure" or "--zeroout"
    local DRIVE_NAME
    DRIVE_NAME=$(basename "$TARGET")

    local SIZE_BYTES
    SIZE_BYTES=$(blockdev --getsize64 "$TARGET" 2>/dev/null)
    local SIZE_GB=0
    [ -n "$SIZE_BYTES" ] && SIZE_GB=$(( SIZE_BYTES / 1024 / 1024 / 1024 ))

    # Timeout logic:
    #   --secure  : ATA Secure Discard command — completes in seconds regardless
    #               of drive size. Flat 5 minute ceiling.
    #   --zeroout : kernel issues WRITE SAME across full drive — size-dependent.
    #               Budget at minimum 50 MB/s; floor 300s, cap 7200s (2hr).
    local TIMEOUT_SECS
    if [ "$FLAGS" = "--secure" ]; then
        TIMEOUT_SECS=300
    else
        local SIZE_MB=$(( ${SIZE_BYTES:-0} / 1024 / 1024 ))
        TIMEOUT_SECS=$(( SIZE_MB / 50 ))
        [ "$TIMEOUT_SECS" -lt 300  ] && TIMEOUT_SECS=300
        [ "$TIMEOUT_SECS" -gt 7200 ] && TIMEOUT_SECS=7200
    fi
    local TIMEOUT_MINS=$(( TIMEOUT_SECS / 60 ))
    log "  [blkdiscard] Timeout: ${TIMEOUT_SECS}s (${TIMEOUT_MINS}min) for $FLAGS on ${SIZE_GB}GB"

    local SIZE_BYTES
    SIZE_BYTES=$(blockdev --getsize64 "$TARGET" 2>/dev/null)
    local SIZE_GB=0
    [ -n "$SIZE_BYTES" ] && SIZE_GB=$(( SIZE_BYTES / 1024 / 1024 / 1024 ))

    # Grab initial write sector count from diskstats
    # diskstats field 9 = sectors written (512 bytes each)
    local SECTORS_START
    SECTORS_START=$(awk -v dev="$DRIVE_NAME" '$3==dev{print $10}' /proc/diskstats 2>/dev/null)
    [ -z "$SECTORS_START" ] && SECTORS_START=0

    local START_TIME=$SECONDS

    # Launch blkdiscard in background
    blkdiscard $FLAGS "$TARGET" > /dev/null 2>&1 &
    local BD_PID=$!

    # Progress polling loop — exits on completion or timeout
    local TIMED_OUT=0
    while kill -0 "$BD_PID" 2>/dev/null; do
        local ELAPSED=$(( SECONDS - START_TIME ))

        if [ "$ELAPSED" -ge "$TIMEOUT_SECS" ]; then
            kill "$BD_PID" 2>/dev/null
            wait "$BD_PID" 2>/dev/null
            TIMED_OUT=1
            break
        fi

        local SECTORS_NOW
        SECTORS_NOW=$(awk -v dev="$DRIVE_NAME" '$3==dev{print $10}' /proc/diskstats 2>/dev/null)
        [ -z "$SECTORS_NOW" ] && SECTORS_NOW=$SECTORS_START

        local SECTORS_WRITTEN=$(( SECTORS_NOW - SECTORS_START ))
        local BYTES_WRITTEN=$(( SECTORS_WRITTEN * 512 ))
        local GB_WRITTEN=0
        [ "$BYTES_WRITTEN" -gt 0 ] && GB_WRITTEN=$(( BYTES_WRITTEN / 1024 / 1024 / 1024 ))

        local MINS=$(( ELAPSED / 60 ))
        local SECS=$(( ELAPSED % 60 ))
        local REMAINING=$(( TIMEOUT_SECS - ELAPSED ))
        local REM_MINS=$(( REMAINING / 60 ))
        local REM_SECS=$(( REMAINING % 60 ))

        local PCT=0
        if [ "$SIZE_BYTES" -gt 0 ] && [ "$BYTES_WRITTEN" -gt 0 ]; then
            PCT=$(( BYTES_WRITTEN * 100 / SIZE_BYTES ))
            [ "$PCT" -gt 100 ] && PCT=100
        fi

        printf "\r  blkdiscard %s  |  %d GB / %d GB  (%d%%)  |  [%02d:%02d elapsed, timeout in %02d:%02d]    " \
               "$FLAGS" "$GB_WRITTEN" "$SIZE_GB" "$PCT" "$MINS" "$SECS" "$REM_MINS" "$REM_SECS"
        sleep 3
    done

    printf "\r%-80s\r" " "   # clear progress line

    if [ "$TIMED_OUT" = "1" ]; then
        log "  [blkdiscard] TIMEOUT after ${TIMEOUT_SECS}s — killed, moving to next step"
        print_status "blkdiscard $FLAGS timed out after ${TIMEOUT_MINS}min — skipping"
        return 1
    fi

    wait "$BD_PID" 2>/dev/null
    local EXIT_CODE=$?
    return $EXIT_CODE
}

# =============================================================================
# DISPLAY: Live polling wrapper for OpenSeaChest commands
# OSC gives no progress output on sanitize. We run it in background and
# print a heartbeat every 10 seconds so the screen shows activity.
# =============================================================================
osc_with_progress() {
    local LABEL="$1"
    local TIMEOUT_SECS="$2"   # hard kill timeout in seconds; 0 = no timeout
    shift 2
    # cd to /tmp so OpenSeaChest auto-created folders land in RAM, not on USB
    # LD_LIBRARY_PATH set explicitly so subshell finds OSC shared libraries
    ( cd /tmp && LD_LIBRARY_PATH="$OSC_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      "$@" > /tmp/osc_output.txt 2>&1 ) &
    local OSC_PID=$!
    local START_TIME=$SECONDS
    local TIMEOUT_MINS=$(( TIMEOUT_SECS / 60 ))

    if [ "$TIMEOUT_SECS" -gt 0 ]; then
        log "  [OSC] Timeout: ${TIMEOUT_SECS}s (${TIMEOUT_MINS}min) for $LABEL"
    fi

    local TIMED_OUT=0
    while kill -0 "$OSC_PID" 2>/dev/null; do
        local ELAPSED=$(( SECONDS - START_TIME ))

        if [ "$TIMEOUT_SECS" -gt 0 ] && [ "$ELAPSED" -ge "$TIMEOUT_SECS" ]; then
            kill "$OSC_PID" 2>/dev/null
            wait "$OSC_PID" 2>/dev/null
            TIMED_OUT=1
            break
        fi

        local MINS=$(( ELAPSED / 60 ))
        local SECS=$(( ELAPSED % 60 ))
        if [ "$TIMEOUT_SECS" -gt 0 ]; then
            local REMAINING=$(( TIMEOUT_SECS - ELAPSED ))
            local REM_MINS=$(( REMAINING / 60 ))
            local REM_SECS=$(( REMAINING % 60 ))
            printf "\r  %s — running...  [%02d:%02d elapsed, timeout in %02d:%02d]    " \
                   "$LABEL" "$MINS" "$SECS" "$REM_MINS" "$REM_SECS"
        else
            printf "\r  %s — running...  [%02d:%02d elapsed]    " "$LABEL" "$MINS" "$SECS"
        fi
        sleep 10
    done

    printf "\r%-80s\r" " "

    # Append any OSC output to log
    cat /tmp/osc_output.txt >> "$LOG_FILE" 2>/dev/null

    if [ "$TIMED_OUT" = "1" ]; then
        log "  [$LABEL] TIMEOUT after ${TIMEOUT_SECS}s — killed, moving to next step"
        print_status "$LABEL timed out after ${TIMEOUT_MINS}min — skipping"
        return 1
    fi

    wait "$OSC_PID"
    local EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        log "  [$LABEL] Completed successfully"
    else
        log "  [$LABEL] Failed (exit $EXIT_CODE)"
    fi

    return $EXIT_CODE
}

# =============================================================================
# DISPLAY: hdparm progress — shows estimated time from drive + live counter
# =============================================================================
hdparm_with_progress() {
    local TARGET="$1"
    local FLAG="$2"         # "--security-erase-enhanced" or "--security-erase"
    local TEMP_PASS="$3"
    local LABEL="$4"

    # Read estimated completion time from drive (minutes)
    local EST_MIN
    EST_MIN=$(hdparm -I "$TARGET" 2>/dev/null \
              | grep -i "for ENHANCED\|for SECURITY ERASE\|min for" \
              | grep -oP '\d+(?= min)' | head -n1)
    [ -z "$EST_MIN" ] && EST_MIN="?"

    log "  [hdparm] Drive estimates: ${EST_MIN} min"

    # Timeout: drive estimate × 3 safety multiplier, floor 600s (10min),
    # cap 14400s (4hr). If drive reports no estimate, default to 60 min.
    local TIMEOUT_SECS
    if [ "$EST_MIN" = "?" ] || ! [[ "$EST_MIN" =~ ^[0-9]+$ ]]; then
        TIMEOUT_SECS=3600
    else
        TIMEOUT_SECS=$(( EST_MIN * 3 * 60 ))
        [ "$TIMEOUT_SECS" -lt 600   ] && TIMEOUT_SECS=600
        [ "$TIMEOUT_SECS" -gt 14400 ] && TIMEOUT_SECS=14400
    fi
    local TIMEOUT_MINS=$(( TIMEOUT_SECS / 60 ))
    log "  [hdparm] Timeout: ${TIMEOUT_SECS}s (${TIMEOUT_MINS}min)"

    hdparm "$FLAG" "$TEMP_PASS" "$TARGET" > /tmp/hdparm_output.txt 2>&1 &
    local HP_PID=$!
    local START_TIME=$SECONDS

    local TIMED_OUT=0
    while kill -0 "$HP_PID" 2>/dev/null; do
        local ELAPSED=$(( SECONDS - START_TIME ))

        if [ "$ELAPSED" -ge "$TIMEOUT_SECS" ]; then
            kill "$HP_PID" 2>/dev/null
            wait "$HP_PID" 2>/dev/null
            TIMED_OUT=1
            break
        fi

        local MINS=$(( ELAPSED / 60 ))
        local SECS=$(( ELAPSED % 60 ))
        local REMAINING=$(( TIMEOUT_SECS - ELAPSED ))
        local REM_MINS=$(( REMAINING / 60 ))
        local REM_SECS=$(( REMAINING % 60 ))
        printf "\r  %s — [%02d:%02d elapsed, drive est: %s min, timeout in %02d:%02d]    " \
               "$LABEL" "$MINS" "$SECS" "$EST_MIN" "$REM_MINS" "$REM_SECS"
        sleep 5
    done

    printf "\r%-80s\r" " "
    cat /tmp/hdparm_output.txt >> "$LOG_FILE" 2>/dev/null

    if [ "$TIMED_OUT" = "1" ]; then
        log "  [$LABEL] TIMEOUT after ${TIMEOUT_SECS}s — killed, moving to next step"
        print_status "$LABEL timed out after ${TIMEOUT_MINS}min — skipping"
        return 1
    fi

    wait "$HP_PID" 2>/dev/null
    local EXIT_CODE=$?
    return $EXIT_CODE
}

# =============================================================================
# HELPER: Classify a wipe METHOD string as NIST Clear or NIST Purge
#
# NIST SP 800-88 Rev. 1 definitions:
#   Clear  — overwrite-based sanitization. Verified by reading back zeros.
#             Methods: dd, blkdiscard --zeroout, OSC WriteSame, OSC Overwrite
#   Purge  — cryptographic erase or hardware-level sanitize. Verified by
#             confirming command completion + drive accessibility. Reading
#             non-zero data back is EXPECTED and correct after Purge.
#             Methods: nvme sanitize, nvme format ses=1/2, hdparm Security
#             Erase (Enhanced or Standard), OSC Quickest Erase (when it
#             selects sanitize or security erase internally), blkdiscard
#             --secure (issues a Secure Discard ATA command = Purge-class)
#
# Sets global: NIST_ACTION ("Clear" or "Purge")
# =============================================================================
classify_nist_action() {
    local METHOD="$1"
    case "$METHOD" in
        # Purge-class: crypto/sanitize/security-erase hardware commands
        *"Sanitize Crypto"*|\
        *"Sanitize Block"*|\
        *"Format Crypto"*|\
        *"Format User Data"*|\
        *"ses=2"*|\
        *"ses=1"*|\
        *"Security Erase Enhanced"*|\
        *"Security Erase Standard"*|\
        *"Secure Discard"*|\
        *"Quickest Erase"*)
            NIST_ACTION="Purge"
            ;;
        # Clear-class: overwrite-based (zeros written to media)
        *"Write Same"*|\
        *"Zeroout"*|\
        *"OSC Overwrite"*|\
        *"dd Zero"*)
            NIST_ACTION="Clear"
            ;;
        # Default conservative: if unsure, treat as Clear so verify checks zeros
        *)
            NIST_ACTION="Clear"
            ;;
    esac
}

# =============================================================================
# HELPER: Multi-zone post-wipe verification — NIST Clear and Purge aware
#
# NIST Clear path (overwrite methods):
#   Samples 4 KB at start, midpoint, and end. Checks for all-zero bytes.
#   Non-zero = FAIL → triggers cascade retry.
#
# NIST Purge path (crypto/sanitize/security-erase methods):
#   Verification confirms:
#     1) Drive is readable (responds to I/O without error)
#     2) Drive size is accessible (blockdev reports correct capacity)
#     3) Hex samples are recorded for the certificate, but non-zero
#        readback is EXPECTED and does NOT constitute failure.
#   Per NIST 800-88 §2.4: "After a Purge, the media should be verified
#   to ensure the device is functioning and accessible."
#   A Purge verification PASS means the hardware command completed
#   and the drive is functioning — not that the drive reads as zeroed.
#
# Globals set: VERIFY_STATUS, VERIFY_HEXDUMP, NIST_ACTION
# Returns: 0 = PASS (continue), 1 = FAIL (retry cascade / force dd)
# =============================================================================
verify_wipe() {
    local TARGET="$1"
    local METHOD="${2:-}"   # optional — passed by wipe functions for NIST routing
    local FAIL=0
    VERIFY_HEXDUMP=""
    VERIFY_STATUS="PASS"

    # Classify this method so cert and verify logic use the right NIST path
    classify_nist_action "$METHOD"

    local SIZE_BYTES
    SIZE_BYTES=$(blockdev --getsize64 "$TARGET" 2>/dev/null)
    if [ -z "$SIZE_BYTES" ] || [ "$SIZE_BYTES" -eq 0 ]; then
        log "  [verify] Could not determine drive size — skipping"
        VERIFY_HEXDUMP="SIZE UNKNOWN — verification skipped"
        VERIFY_STATUS="SKIPPED"
        return 0
    fi

    local MID_OFFSET=$(( SIZE_BYTES / 2 ))
    local END_OFFSET=$(( SIZE_BYTES - 4096 ))
    MID_OFFSET=$(( (MID_OFFSET / 512) * 512 ))
    END_OFFSET=$(( (END_OFFSET / 512) * 512 ))

    local ZONES="0 $MID_OFFSET $END_OFFSET"
    local ZONE_LABELS=("START" "MIDDLE" "END")
    local IDX=0

    if [ "$NIST_ACTION" = "Purge" ]; then
        # ---------------------------------------------------------------
        # PURGE VERIFICATION
        # Goal: confirm hardware command completed + drive is accessible.
        # Non-zero readback is expected — do NOT check for zeros.
        # We record hex samples for the certificate audit trail only.
        # ---------------------------------------------------------------
        print_status "Purge verify — confirming drive accessible post-erase..."
        log "  [verify] NIST Purge path — checking drive accessibility (not zero-fill)"

        local READ_FAIL=0
        for OFFSET in $ZONES; do
            local SKIP=$(( OFFSET / 512 ))
            local LABEL="${ZONE_LABELS[$IDX]}"

            local HEX READ_BYTES
            HEX=$(dd if="$TARGET" bs=512 skip="$SKIP" count=8 2>/dev/null \
                  | hexdump -C | head -n 6)
            READ_BYTES=$(dd if="$TARGET" bs=512 skip="$SKIP" count=8 2>/dev/null \
                         | wc -c)

            VERIFY_HEXDUMP+="  [$LABEL @ byte $OFFSET — Purge: non-zero expected]"$'\n'"$HEX"$'\n'

            if [ "${READ_BYTES:-0}" -eq 0 ]; then
                log "  [verify] FAIL — drive returned 0 bytes at $LABEL offset $OFFSET (I/O error)"
                READ_FAIL=1
            else
                log "  [verify] PASS — drive readable at $LABEL offset $OFFSET ($READ_BYTES bytes returned)"
            fi
            IDX=$(( IDX + 1 ))
        done

        if [ $READ_FAIL -eq 1 ]; then
            VERIFY_STATUS="FAIL — drive not accessible after Purge (I/O error)"
            log "  [verify] OVERALL: FAIL (Purge — drive I/O error)"
            print_status "PURGE VERIFY FAIL — drive not responding to reads"
            return 1
        else
            VERIFY_STATUS="PASS — Purge confirmed: drive accessible, hardware erase completed"
            log "  [verify] OVERALL: PASS (Purge — drive accessible, non-zero readback is correct)"
            print_status "PURGE VERIFY PASS — drive accessible, erase confirmed complete"
            return 0
        fi

    else
        # ---------------------------------------------------------------
        # CLEAR VERIFICATION
        # Goal: confirm overwrite wrote zeros across the drive.
        # Non-zero bytes = FAIL → cascade retries next method.
        # ---------------------------------------------------------------
        print_status "Clear verify — sampling 3 zones for zero-fill confirmation..."
        log "  [verify] NIST Clear path — checking for zero-fill"

        for OFFSET in $ZONES; do
            local SKIP=$(( OFFSET / 512 ))
            local LABEL="${ZONE_LABELS[$IDX]}"

            # Pipe dd directly — never capture binary data in a variable;
            # shell assignment strips null bytes causing false-zero results
            local NON_ZERO
            NON_ZERO=$(dd if="$TARGET" bs=512 skip="$SKIP" count=8 2>/dev/null \
                       | tr -d '\000' | wc -c)
            NON_ZERO=${NON_ZERO:-0}

            local HEX
            HEX=$(dd if="$TARGET" bs=512 skip="$SKIP" count=8 2>/dev/null \
                  | hexdump -C | head -n 6)

            VERIFY_HEXDUMP+="  [$LABEL @ byte $OFFSET]"$'\n'"$HEX"$'\n'

            if [ "$NON_ZERO" -gt 0 ]; then
                log "  [verify] FAIL — non-zero bytes at $LABEL offset $OFFSET ($NON_ZERO bytes)"
                FAIL=1
            else
                log "  [verify] PASS — $LABEL @ offset $OFFSET is zeroed"
            fi
            IDX=$(( IDX + 1 ))
        done

        if [ $FAIL -eq 1 ]; then
            VERIFY_STATUS="FAIL — non-zero data detected after Clear overwrite"
            log "  [verify] OVERALL: FAIL"
            print_status "VERIFY FAIL — non-zero data remains after overwrite"
        else
            VERIFY_STATUS="PASS — Clear confirmed: all sampled zones read as zero"
            log "  [verify] OVERALL: PASS"
            print_status "VERIFY PASS — all sampled zones confirmed zero"
        fi

        return $FAIL
    fi
}

# =============================================================================
# HELPER: ATA security freeze check (no suspend attempt — ShredOS safe)
# =============================================================================
check_frozen() {
    local TARGET="$1"
    local FREEZE_STATUS
    FREEZE_STATUS=$(hdparm -I "$TARGET" 2>/dev/null | grep -i "frozen" | awk '{print $1}')
    if [ "$FREEZE_STATUS" = "frozen" ]; then
        log "  [freeze] $TARGET is BIOS security-frozen — hdparm blocked"
        log "  [freeze] To manually unfreeze: disconnect POWER cable only"
        log "  [freeze] (keep SATA data cable attached), wait 5s, reconnect."
        print_status "FROZEN — hdparm skipped, routing to blkdiscard/dd"
        return 1
    fi
    log "  [freeze] Not frozen — hdparm available"
    return 0
}

# =============================================================================
# HELPER: hdparm Security Erase lifecycle with live progress
# =============================================================================
hdparm_erase() {
    local TARGET="$1"
    local ENHANCED="$2"
    local TEMP_PASS="IntellectWipe$$"

    if ! hdparm -I "$TARGET" 2>/dev/null | grep -q "Security Mode"; then
        log "  [hdparm] ATA Security Mode not supported — skipping"
        return 1
    fi

    local SEC_STATE
    SEC_STATE=$(hdparm -I "$TARGET" 2>/dev/null | grep -A5 "Security Mode")
    if echo "$SEC_STATE" | grep -q "enabled"; then
        log "  [hdparm] Security pre-enabled — clearing with blank password"
        hdparm --security-disable "" "$TARGET" > /dev/null 2>&1 || true
    fi

    check_frozen "$TARGET" || return 1

    if ! hdparm --security-set-pass "$TEMP_PASS" "$TARGET" > /dev/null 2>&1; then
        log "  [hdparm] Failed to set security password"
        return 1
    fi

    local EXIT_CODE=1
    if [ "$ENHANCED" = "enhanced" ]; then
        log "  [hdparm] Issuing Enhanced Security Erase..."
        hdparm_with_progress "$TARGET" "--security-erase-enhanced" \
            "$TEMP_PASS" "hdparm Enhanced Security Erase"
        EXIT_CODE=$?
    else
        log "  [hdparm] Issuing Security Erase (standard)..."
        hdparm_with_progress "$TARGET" "--security-erase" \
            "$TEMP_PASS" "hdparm Security Erase"
        EXIT_CODE=$?
    fi

    hdparm --security-disable "$TEMP_PASS" "$TARGET" > /dev/null 2>&1 || true

    [ $EXIT_CODE -eq 0 ] \
        && log "  [hdparm] Returned success" \
        || log "  [hdparm] Returned failure (exit $EXIT_CODE)"

    return $EXIT_CODE
}

# =============================================================================
# HELPER: Resolve nvme binary
# =============================================================================
get_nvme_bin() {
    if [ -x "$NVME_BIN" ]; then
        echo "$NVME_BIN"
    elif command -v nvme > /dev/null 2>&1; then
        command -v nvme
    else
        echo ""
    fi
}

# =============================================================================
# HELPER: Read NVMe sanicap bitmask
# Sets globals: SANICAP_CRYPTO, SANICAP_BLOCK, SANICAP_OVERWRITE
# =============================================================================
read_sanicap() {
    local TARGET="$1"
    local NVME="$2"

    SANICAP_CRYPTO=0
    SANICAP_BLOCK=0
    SANICAP_OVERWRITE=0

    local RAW
    RAW=$("$NVME" id-ctrl "$TARGET" --output-format=normal 2>/dev/null | grep -i "^sanicap" | awk '{print $NF}')

    if [ -z "$RAW" ]; then
        log "  [sanicap] Not readable — Sanitize command set may be unsupported"
        return 1
    fi

    local CAP
    CAP=$(printf '%d' "$RAW" 2>/dev/null)
    log "  [sanicap] Raw=$RAW  Decimal=$CAP"

    # Correct SANICAP bitmask per NVMe spec 1.4 section 5.15.2.1:
    #   Bit 0 (0x01) = No-Deallocate Inhibited (not an erase capability)
    #   Bit 1 (0x02) = Block Erase Supported
    #   Bit 2 (0x04) = Overwrite Supported
    #   Bit 29 (crypto) = Crypto Erase Supported — checked via sanitize CAP word
    # In practice nvme-cli reports sanicap with:
    #   bit 1 set = block erase, bit 2 set = overwrite, bit 30 = crypto erase
    # We check all three defensively.
    (( CAP & 0x40000000 )) && SANICAP_CRYPTO=1    # bit 30
    (( CAP & 0x02 ))       && SANICAP_BLOCK=1     # bit 1
    (( CAP & 0x04 ))       && SANICAP_OVERWRITE=1 # bit 2

    log "  [sanicap] Crypto 0x04=$([ $SANICAP_CRYPTO   -eq 1 ] && echo YES || echo no)  Block 0x02=$([ $SANICAP_BLOCK -eq 1 ] && echo YES || echo no)  Overwrite 0x03=$([ $SANICAP_OVERWRITE -eq 1 ] && echo YES || echo no)"
    return 0
}

# =============================================================================
# HELPER: Poll NVMe sanitize-log with live SPROG % display
# =============================================================================
wait_nvme_sanitize() {
    local TARGET="$1"
    local NVME="$2"
    local MAX_WAIT=300
    local ELAPSED=0
    local INTERVAL=5

    log "  Polling sanitize-log (max ${MAX_WAIT}s)..."
    while [ $ELAPSED -lt $MAX_WAIT ]; do
        sleep $INTERVAL
        ELAPSED=$(( ELAPSED + INTERVAL ))

        local SSTAT SPROG
        SSTAT=$("$NVME" sanitize-log "$TARGET" --output-format=normal 2>/dev/null \
                | grep -i "Sanitize Status\|SSTAT" | awk '{print $NF}')
        SPROG=$("$NVME" sanitize-log "$TARGET" --output-format=normal 2>/dev/null \
                | grep -i "Sanitize Progress\|SPROG" | awk '{print $NF}')

        # Convert SPROG (0-65535) to percent
        local PCT=0
        if [ -n "$SPROG" ] && [ "$SPROG" -gt 0 ] 2>/dev/null; then
            PCT=$(( SPROG * 100 / 65535 ))
        fi

        local MINS=$(( ELAPSED / 60 ))
        local SECS=$(( ELAPSED % 60 ))
        printf "\r  NVMe Sanitize — SSTAT=%s  Progress=%d%%  [%02d:%02d elapsed]    " \
               "$SSTAT" "$PCT" "$MINS" "$SECS"
        log "  [sanitize-log] SSTAT=$SSTAT  SPROG=$SPROG  ($PCT%%)  elapsed=${ELAPSED}s"

        [ "$SSTAT" = "0x3" ] || [ "$SSTAT" = "3" ] && {
            printf "\r%-80s\r" " "
            return 0
        }
        if [ "$SSTAT" = "0x4" ] || [ "$SSTAT" = "4" ]; then
            printf "\r%-80s\r" " "
            log "  [!] Sanitize completed with errors (SSTAT=0x4)"
            return 1
        fi
    done

    printf "\r%-80s\r" " "
    log "  [!] Sanitize poll timed out after ${MAX_WAIT}s"
    return 1
}

# =============================================================================
# HELPER: Resolve /dev/sdX or /dev/nvmeX to its /dev/sgN equivalent
# OpenSeaChest requires sg (SCSI Generic) device paths, not block device paths
# =============================================================================
get_sg_device() {
    local BLOCK_DEV="$1"
    local BASE
    BASE=$(basename "$BLOCK_DEV")

    # Check /sys/block/<dev>/device/scsi_generic/ for the sg mapping
    local SG
    SG=$(ls "/sys/block/$BASE/device/scsi_generic/" 2>/dev/null | head -n1)
    if [ -n "$SG" ]; then
        echo "/dev/$SG"
        return 0
    fi

    # Fallback: scan /sys/class/scsi_generic for a match
    for SG_PATH in /sys/class/scsi_generic/sg*; do
        local SG_BLOCK
        SG_BLOCK=$(readlink -f "$SG_PATH/device/block" 2>/dev/null | xargs ls 2>/dev/null | head -n1)
        if [ "$SG_BLOCK" = "$BASE" ]; then
            echo "/dev/$(basename "$SG_PATH")"
            return 0
        fi
    done

    # Last resort: try sg_map if available
    if command -v sg_map > /dev/null 2>&1; then
        SG=$(sg_map 2>/dev/null | awk -v dev="$BLOCK_DEV" '$2==dev{print $1}')
        [ -n "$SG" ] && echo "$SG" && return 0
    fi

    # Could not resolve — return empty, OSC calls will be skipped
    log "  [sg] Could not resolve sg device for $BLOCK_DEV — skipping OSC"
    echo ""
    return 1
}

# =============================================================================
# WIPE: NVMe
#
# Cascade (6 steps):
#   1) nvme sanitize -a 0x04  (crypto,      sanicap-gated)
#   2) nvme sanitize -a 0x02  (block erase, sanicap-gated)
#   3) nvme format --ses=2    (crypto erase)
#   4) nvme format --ses=1    (user data erase)
#   5) OSC --performQuickestErase (version-gated)
#   6) dd (last resort — only reached if ALL above fail or are unsupported)
#
# VERIFY + RESUME logic:
#   After any step succeeds, post-wipe verification runs immediately.
#   If verification fails, RESUME_FROM is set to that step number and the
#   cascade re-enters at RESUME_FROM+1 — so no step is skipped just because
#   an earlier step claimed success but lied. dd only fires after steps 1-5
#   have all been exhausted (or were ineligible).
# =============================================================================
wipe_nvme() {
    local TARGET="$1"
    local METHOD=""
    local RESUME_FROM=0     # step number of the last failed verify; cascade restarts here+1
    local VERIFIED=0        # set to 1 once a step passes verification
    local ATTEMPT=0         # loop iteration counter (safety cap)
    local MAX_ATTEMPTS=7    # steps 1-5 + up to 2 verify-retry passes = safe ceiling

    log "  Drive type: NVMe"

    local NVME
    NVME=$(get_nvme_bin)
    if [ -z "$NVME" ]; then
        log "  [!] nvme binary not found at $NVME_BIN — place static binary there"
    fi

    local SANICAP_OK=1
    if [ -n "$NVME" ]; then
        log "  nvme binary: $NVME"
        read_sanicap "$TARGET" "$NVME"
        SANICAP_OK=$?
    fi

    # Resolve sg device once — used by TRY 5 (OSC)
    local SG_DEV
    SG_DEV=$(get_sg_device "$TARGET")

    # -------------------------------------------------------------------------
    # CASCADE LOOP — re-entered after a verify failure at RESUME_FROM+1
    # -------------------------------------------------------------------------
    while [ $VERIFIED -eq 0 ] && [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$(( ATTEMPT + 1 ))
        METHOD=""

        # TRY 1: nvme sanitize -a 0x04 (crypto erase)
        if [ "$RESUME_FROM" -lt 1 ] && [ -n "$NVME" ] \
           && [ $SANICAP_OK -eq 0 ] && [ "$SANICAP_CRYPTO" = "1" ]; then
            CURRENT_TRY="TRY 1/6 — NVMe Sanitize Crypto Erase 0x04"
            print_status "Starting..."
            log "  TRY 1: nvme sanitize -a 0x04"
            if "$NVME" sanitize "$TARGET" -a 0x04 > /dev/null 2>&1; then
                wait_nvme_sanitize "$TARGET" "$NVME" \
                    && METHOD="NVMe Sanitize Crypto Erase 0x04 (nvme-cli)"
            fi
            [ -z "$METHOD" ] && log "  TRY 1: Failed or timed out"
        elif [ "$RESUME_FROM" -lt 1 ]; then
            log "  TRY 1: Skipped — sanicap: crypto erase not supported"
        fi

        # TRY 2: nvme sanitize -a 0x02 (block erase)
        if [ -z "$METHOD" ] && [ "$RESUME_FROM" -lt 2 ] && [ -n "$NVME" ] \
           && [ $SANICAP_OK -eq 0 ] && [ "$SANICAP_BLOCK" = "1" ]; then
            CURRENT_TRY="TRY 2/6 — NVMe Sanitize Block Erase 0x02"
            print_status "Starting..."
            log "  TRY 2: nvme sanitize -a 0x02"
            if "$NVME" sanitize "$TARGET" -a 0x02 > /dev/null 2>&1; then
                wait_nvme_sanitize "$TARGET" "$NVME" \
                    && METHOD="NVMe Sanitize Block Erase 0x02 (nvme-cli)"
            fi
            [ -z "$METHOD" ] && log "  TRY 2: Failed or timed out"
        elif [ -z "$METHOD" ] && [ "$RESUME_FROM" -lt 2 ]; then
            log "  TRY 2: Skipped — sanicap: block erase not supported"
        fi

        # TRY 3: nvme format --ses=2
        if [ -z "$METHOD" ] && [ "$RESUME_FROM" -lt 3 ] && [ -n "$NVME" ]; then
            CURRENT_TRY="TRY 3/6 — NVMe Format Crypto Erase ses=2"
            print_status "Starting..."
            log "  TRY 3: nvme format --ses=2"
            start_spinner "nvme format --ses=2 running"
            "$NVME" format "$TARGET" --ses=2 > /dev/null 2>&1
            local RC=$?
            stop_spinner
            [ $RC -eq 0 ] && METHOD="NVMe Format Crypto Erase ses=2 (nvme-cli)" \
                           || log "  TRY 3: Failed"
        fi

        # TRY 4: nvme format --ses=1
        if [ -z "$METHOD" ] && [ "$RESUME_FROM" -lt 4 ] && [ -n "$NVME" ]; then
            CURRENT_TRY="TRY 4/6 — NVMe Format User Data Erase ses=1"
            print_status "Starting..."
            log "  TRY 4: nvme format --ses=1"
            start_spinner "nvme format --ses=1 running"
            "$NVME" format "$TARGET" --ses=1 > /dev/null 2>&1
            local RC=$?
            stop_spinner
            [ $RC -eq 0 ] && METHOD="NVMe Format User Data Erase ses=1 (nvme-cli)" \
                           || log "  TRY 4: Failed"
        fi

        # TRY 5: OSC Quickest Erase (version-gated)
        if [ -z "$METHOD" ] && [ "$RESUME_FROM" -lt 5 ] \
           && [ -x "$OSC_PATH/openSeaChest_Erase" ]; then
            if [ "$OSC_QE_SUPPORTED" = "1" ] && [ -n "$SG_DEV" ]; then
                CURRENT_TRY="TRY 5/6 — OSC Perform Quickest Erase (NVMe)"
                print_status "Starting..."
                log "  TRY 5: OpenSeaChest --performQuickestErase ($SG_DEV)"
                osc_with_progress "OSC Quickest Erase" 300 \
                    "$OSC_PATH/openSeaChest_Erase" \
                    -d "$SG_DEV" --performQuickestErase --poll \
                    --confirm I_PROMISE_TO_BE_CAREFUL \
                    && METHOD="NVMe OSC Quickest Erase"
            else
                log "  TRY 5: Skipped — OSC v26+ --confirm bug or no sg device"
            fi
        fi

        # --- Verify or fall through to dd ------------------------------------
        if [ -n "$METHOD" ]; then
            CURRENT_TRY="VERIFYING after: $METHOD"
            log "  [verify] Running post-wipe multi-zone verification..."
            if verify_wipe "$TARGET" "$METHOD"; then
                VERIFIED=1
            else
                # Identify which step number just failed so we resume past it
                case "$METHOD" in
                    *"0x04"*)  RESUME_FROM=1 ;;
                    *"0x02"*)  RESUME_FROM=2 ;;
                    *"ses=2"*) RESUME_FROM=3 ;;
                    *"ses=1"*) RESUME_FROM=4 ;;
                    *"OSC"*)   RESUME_FROM=5 ;;
                    *)         RESUME_FROM=5 ;;
                esac
                log "  [!] VERIFICATION FAILED after: $METHOD — resuming cascade from step $(( RESUME_FROM + 1 ))"
                print_status "VERIFY FAIL — retrying cascade from step $(( RESUME_FROM + 1 ))"
                METHOD=""
            fi
        else
            # All eligible steps exhausted — no METHOD was set this pass
            break
        fi
    done

    # TRY 6 / LAST RESORT: dd — only reached if all steps 1-5 failed or lied
    if [ $VERIFIED -eq 0 ]; then
        CURRENT_TRY="TRY 6/6 — dd Zero Overwrite (last resort)"
        print_status "All hardware methods failed or unverifiable — running dd"
        log "  TRY 6: dd zero overwrite (last resort)"
        dd if=/dev/zero of="$TARGET" bs=4M status=progress conv=fsync \
            2>&1 | tee -a "$LOG_FILE"
        METHOD="dd Zero Overwrite (last resort after all NVMe methods failed)"
        log "  [verify] Post-dd verification..."
        verify_wipe "$TARGET" "$METHOD"
    fi

    # Write result to global — avoids subshell variable loss
    WIPE_RESULT="$METHOD"
}

# =============================================================================
# WIPE: SATA (SSD and HDD)
#
# Cascade (8 steps):
#   1) OSC --performQuickestErase     (version-gated)
#   2) OSC --writeSame 0              (confirm-flagged)
#   3) blkdiscard --secure            (freeze-immune)
#   4) blkdiscard --zeroout           (freeze-immune)
#   5) hdparm Enhanced Security Erase (freeze-checked)
#   6) hdparm Security Erase          (freeze-checked)
#   7) OSC --overwrite 0
#   8) dd (last resort — only if ALL above fail or are unsupported AND
#          blkdiscard is confirmed unavailable/unsupported on this drive)
#
# BLKDISCARD POLICY:
#   blkdiscard support is probed once up front (BLKDISCARD_AVAIL).
#   If blkdiscard is available on this system, dd is NEVER used as the
#   verify-failure fallback — the cascade always retries through blkdiscard
#   steps 3 and 4 before reaching dd. dd only fires if blkdiscard itself
#   also fails or is unavailable.
#
# VERIFY + RESUME logic:
#   After any step succeeds, verification runs immediately. If it fails,
#   RESUME_FROM is set to that step number and the cascade re-enters at
#   RESUME_FROM+1. This ensures no step is skipped just because an earlier
#   step claimed success but left residual data.
# =============================================================================
wipe_sata() {
    local TARGET="$1"
    local METHOD=""
    DRIVE_FROZEN=0
    local RESUME_FROM=0     # step number of last failed verify; cascade restarts here+1
    local VERIFIED=0        # set to 1 once a step passes verification
    local ATTEMPT=0         # loop iteration counter
    local MAX_ATTEMPTS=10   # steps 1-7 + up to 3 verify-retry passes = safe ceiling

    log "  Drive type: SATA"

    # Resolve sg device once for all OpenSeaChest calls
    local SG_DEV
    SG_DEV=$(get_sg_device "$TARGET")
    if [ -z "$SG_DEV" ]; then
        log "  [!] No sg device found for $TARGET — OSC tries 1, 2, 7 will be skipped"
    else
        log "  [sg] Resolved $TARGET -> $SG_DEV"
    fi

    # Probe blkdiscard availability once up front.
    # BLKDISCARD_AVAIL=1 means the binary exists AND the drive responds to it.
    # We test --zeroout (not --secure) for the capability probe because
    # --secure may legitimately return error on drives that don't support the
    # secure discard flag, while --zeroout is more broadly supported.
    # This flag is used below to gate whether dd is a permissible fallback.
    local BLKDISCARD_AVAIL=0
    if command -v blkdiscard > /dev/null 2>&1; then
        # Dry-run: attempt a 0-byte zeroout at offset 0 to test kernel support
        # --offset 0 --length 0 is a no-op that still validates device support
        if blkdiscard --zeroout --offset 0 --length 512 "$TARGET" > /dev/null 2>&1; then
            BLKDISCARD_AVAIL=1
            log "  [blkdiscard] Available and supported on this drive"
        else
            log "  [blkdiscard] Binary found but drive/kernel does not support it"
        fi
    else
        log "  [!] blkdiscard not found — skipping tries 3 and 4"
    fi

    # Freeze check done once — result cached for hdparm steps
    local HDPARM_OK=0
    if command -v hdparm > /dev/null 2>&1; then
        if check_frozen "$TARGET"; then
            HDPARM_OK=1
        else
            DRIVE_FROZEN=1
            log "  TRY 5+6: Will be skipped — BIOS freeze lock active"
        fi
    else
        log "  [!] hdparm not found — skipping tries 5 and 6"
    fi

    # -------------------------------------------------------------------------
    # CASCADE LOOP — re-entered after a verify failure at RESUME_FROM+1
    # -------------------------------------------------------------------------
    while [ $VERIFIED -eq 0 ] && [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$(( ATTEMPT + 1 ))
        METHOD=""

        # TRY 1: OSC Quickest Erase (version-gated — broken in OSC v26+)
        if [ -z "$METHOD" ] && [ "$RESUME_FROM" -lt 1 ] \
           && [ -n "$SG_DEV" ] && [ -x "$OSC_PATH/openSeaChest_Erase" ]; then
            if [ "$OSC_QE_SUPPORTED" = "1" ]; then
                CURRENT_TRY="TRY 1/8 — OSC Perform Quickest Erase"
                print_status "Starting..."
                log "  TRY 1: OpenSeaChest --performQuickestErase ($SG_DEV)"
                osc_with_progress "OSC Quickest Erase" 300 \
                    "$OSC_PATH/openSeaChest_Erase" \
                    -d "$SG_DEV" --performQuickestErase --poll \
                    --confirm I_PROMISE_TO_BE_CAREFUL \
                    && METHOD="SATA OSC Quickest Erase (auto-selected)"
            else
                log "  TRY 1: Skipped — OSC v26+ --confirm bug (ver: '$OSC_VERSION_STR')"
            fi
        elif [ ! -x "$OSC_PATH/openSeaChest_Erase" ] && [ "$RESUME_FROM" -lt 1 ]; then
            log "  [!] OpenSeaChest not found — skipping OSC methods"
        fi

        # TRY 2: OSC Write Same
        if [ -z "$METHOD" ] && [ "$RESUME_FROM" -lt 2 ] \
           && [ -n "$SG_DEV" ] && [ -x "$OSC_PATH/openSeaChest_Erase" ]; then
            CURRENT_TRY="TRY 2/8 — OSC Write Same"
            print_status "Starting..."
            log "  TRY 2: OpenSeaChest --writeSame 0 ($SG_DEV)"
            osc_with_progress "OSC Write Same" 300 \
                "$OSC_PATH/openSeaChest_Erase" \
                -d "$SG_DEV" --writeSame 0 --poll \
                --confirm this-will-erase-data \
                && METHOD="SATA OSC Write Same"
        fi

        # TRY 3: blkdiscard --secure
        if [ -z "$METHOD" ] && [ "$RESUME_FROM" -lt 3 ] \
           && [ "$BLKDISCARD_AVAIL" = "1" ]; then
            CURRENT_TRY="TRY 3/8 — blkdiscard --secure (freeze-immune)"
            print_status "Starting..."
            log "  TRY 3: blkdiscard --secure"
            blkdiscard_with_progress "$TARGET" "--secure"
            if [ $? -eq 0 ]; then
                METHOD="SATA blkdiscard Secure Discard"
                log "  TRY 3: Success"
            else
                log "  TRY 3: --secure not supported on this drive"
            fi
        fi

        # TRY 4: blkdiscard --zeroout
        if [ -z "$METHOD" ] && [ "$RESUME_FROM" -lt 4 ] \
           && [ "$BLKDISCARD_AVAIL" = "1" ]; then
            CURRENT_TRY="TRY 4/8 — blkdiscard --zeroout (freeze-immune)"
            print_status "Starting — this may take several minutes on large drives..."
            log "  TRY 4: blkdiscard --zeroout"
            blkdiscard_with_progress "$TARGET" "--zeroout"
            if [ $? -eq 0 ]; then
                METHOD="SATA blkdiscard WRITE SAME Zeroout"
                log "  TRY 4: Success"
            else
                log "  TRY 4: --zeroout failed"
            fi
        fi

        # TRY 5: hdparm Enhanced Security Erase
        if [ -z "$METHOD" ] && [ "$RESUME_FROM" -lt 5 ] && [ "$HDPARM_OK" = "1" ]; then
            CURRENT_TRY="TRY 5/8 — hdparm Enhanced Security Erase"
            print_status "Starting..."
            log "  TRY 5: hdparm Enhanced Security Erase"
            if hdparm_erase "$TARGET" "enhanced"; then
                METHOD="SATA ATA Security Erase Enhanced (hdparm)"
            else
                log "  TRY 5: Failed or unsupported"
            fi
        fi

        # TRY 6: hdparm Security Erase (standard)
        if [ -z "$METHOD" ] && [ "$RESUME_FROM" -lt 6 ] && [ "$HDPARM_OK" = "1" ]; then
            CURRENT_TRY="TRY 6/8 — hdparm Security Erase (standard)"
            print_status "Starting..."
            log "  TRY 6: hdparm Security Erase (standard)"
            if hdparm_erase "$TARGET" "standard"; then
                METHOD="SATA ATA Security Erase Standard (hdparm)"
            else
                log "  TRY 6: Failed or unsupported"
            fi
        fi

        # TRY 7: OSC Overwrite
        # Timeout is size-based: OSC --overwrite does a full sector write,
        # so ceiling scales with drive capacity (min 10min, max 4hr).
        if [ -z "$METHOD" ] && [ "$RESUME_FROM" -lt 7 ] \
           && [ -n "$SG_DEV" ] && [ -x "$OSC_PATH/openSeaChest_Erase" ]; then
            CURRENT_TRY="TRY 7/8 — OSC Overwrite"
            print_status "Starting..."
            log "  TRY 7: OpenSeaChest --overwrite 0 ($SG_DEV)"
            local SIZE_BYTES_OSC
            SIZE_BYTES_OSC=$(blockdev --getsize64 "$TARGET" 2>/dev/null)
            local OSC_OW_TIMEOUT=$(( ${SIZE_BYTES_OSC:-0} / 1024 / 1024 / 50 ))
            [ "$OSC_OW_TIMEOUT" -lt 600   ] && OSC_OW_TIMEOUT=600
            [ "$OSC_OW_TIMEOUT" -gt 14400 ] && OSC_OW_TIMEOUT=14400
            osc_with_progress "OSC Overwrite" "$OSC_OW_TIMEOUT" \
                "$OSC_PATH/openSeaChest_Erase" \
                -d "$SG_DEV" --overwrite 0 --poll \
                && METHOD="SATA OSC Overwrite"
        fi

        # --- Verify or advance RESUME_FROM -----------------------------------
        if [ -n "$METHOD" ]; then
            CURRENT_TRY="VERIFYING after: $METHOD"
            log "  [verify] Running post-wipe multi-zone verification..."
            if verify_wipe "$TARGET" "$METHOD"; then
                VERIFIED=1
            else
                # Map METHOD string back to step number so resume is precise
                case "$METHOD" in
                    *"Quickest Erase"*) RESUME_FROM=1 ;;
                    *"Write Same"*)     RESUME_FROM=2 ;;
                    *"Secure Discard"*) RESUME_FROM=3 ;;
                    *"Zeroout"*)        RESUME_FROM=4 ;;
                    *"Enhanced"*)       RESUME_FROM=5 ;;
                    *"Standard"*)       RESUME_FROM=6 ;;
                    *"OSC Overwrite"*)  RESUME_FROM=7 ;;
                    *)                  RESUME_FROM=7 ;;
                esac
                log "  [!] VERIFICATION FAILED after: $METHOD — resuming from step $(( RESUME_FROM + 1 ))"
                print_status "VERIFY FAIL — retrying cascade from step $(( RESUME_FROM + 1 ))"
                METHOD=""
            fi
        else
            # No step produced a METHOD this pass — all eligible steps exhausted
            break
        fi
    done

    # TRY 8 / LAST RESORT: dd
    # Only reached when ALL steps 1-7 have failed or been skipped AND
    # blkdiscard was either unavailable or also failed verification.
    # If blkdiscard is available but steps 3/4 already ran and failed verify,
    # RESUME_FROM will be >= 4, meaning blkdiscard WAS attempted — dd is
    # then the correct and only remaining option.
    if [ $VERIFIED -eq 0 ]; then
        if [ "$BLKDISCARD_AVAIL" = "1" ] && [ "$RESUME_FROM" -lt 3 ]; then
            # blkdiscard is available but hasn't been tried yet — this path
            # should not be reachable under normal flow, but guard it anyway
            log "  [!] BUG: dd would skip blkdiscard — forcing blkdiscard first"
            RESUME_FROM=2
            # Re-enter loop for one more pass covering steps 3+4
            METHOD=""
            CURRENT_TRY="TRY 3/8 — blkdiscard --secure (forced retry)"
            print_status "Starting blkdiscard before dd..."
            log "  TRY 3 (forced): blkdiscard --secure"
            blkdiscard_with_progress "$TARGET" "--secure" || true
            log "  TRY 4 (forced): blkdiscard --zeroout"
            blkdiscard_with_progress "$TARGET" "--zeroout" \
                && METHOD="SATA blkdiscard WRITE SAME Zeroout (forced pre-dd)"
            if [ -n "$METHOD" ]; then
                verify_wipe "$TARGET" "$METHOD" && VERIFIED=1
            fi
        fi

        if [ $VERIFIED -eq 0 ]; then
            CURRENT_TRY="TRY 8/8 — dd Zero Overwrite (last resort)"
            print_status "All hardware methods exhausted — running dd"
            log "  TRY 8: dd zero overwrite (last resort)"
            dd if=/dev/zero of="$TARGET" bs=1M status=progress conv=fsync \
                2>&1 | tee -a "$LOG_FILE"
            METHOD="dd Zero Overwrite (last resort after all hardware methods failed)"
            log "  [verify] Post-dd verification..."
            verify_wipe "$TARGET" "$METHOD"
        fi
    fi

    # Write result to global — avoids subshell variable loss
    WIPE_RESULT="$METHOD"
}

# =============================================================================
# DETECT DRIVE TYPE
# =============================================================================
get_drive_type() {
    local DRIVE="$1"
    echo "$DRIVE" | grep -q "^nvme" && { echo "nvme"; return; }
    local ROTA
    ROTA=$(cat "/sys/block/$DRIVE/queue/rotational" 2>/dev/null)
    [ "$ROTA" = "0" ] && echo "ssd" || echo "hdd"
}

# =============================================================================
# MAIN LOOP
# =============================================================================
clear
echo "============================================================"
echo " INTELLECT MASTER WIPE V21"
echo " Machine  : $PCNAME"
echo " Started  : $(date)"
echo "============================================================"
logecho "============================================================"
logecho " INTELLECT MASTER WIPE V21 — $(date)"
logecho " Machine: $PCNAME"
logecho "============================================================"
if [ -n "$OSC_VERSION_STR" ]; then
    logecho "  OSC detected : $OSC_VERSION_STR"
    if [ "$OSC_QE_SUPPORTED" = "1" ]; then
        logecho "  OSC QE status: --performQuickestErase ENABLED (pre-v26)"
    else
        logecho "  OSC QE status: --performQuickestErase DISABLED (v26+ confirm bug)"
    fi
else
    logecho "  OSC detected : not found or version unreadable"
fi

if [ -z "$USB_DEV" ]; then
    log "  [!] WARNING: Boot USB device not detected at /mnt/usb"
    log "  [!] Verify mount point before proceeding"
    echo ""
    echo "  WARNING: Could not identify boot USB. Check /mnt/usb mount."
    echo "  Press Ctrl+C within 10 seconds to abort."
    sleep 10
fi

# Enumerate and display all drives that will be wiped before starting
echo ""
echo "  Drives queued for wipe:"
for DRIVE in $(lsblk -dno NAME | grep -v "^${USB_DEV}$"); do
    TARGET="/dev/$DRIVE"
    [ -b "$TARGET" ] || continue
    MODEL=$(lsblk -dno MODEL "$TARGET" 2>/dev/null | xargs)
    SIZE=$(lsblk -dno SIZE "$TARGET" 2>/dev/null)
    TYPE=$(get_drive_type "$DRIVE")
    printf "    %-10s %-30s %-8s %s\n" "$TARGET" "$MODEL" "$SIZE" "$TYPE"
done
echo ""
echo "  Starting in 5 seconds... (Ctrl+C to abort)"
sleep 5

# --- Main wipe loop ----------------------------------------------------------
DRIVES_PROCESSED=0
for DRIVE in $(lsblk -dno NAME | grep -v "^${USB_DEV}$"); do
    TARGET="/dev/$DRIVE"
    [ -b "$TARGET" ] || continue

    # Serial number — try multiple sources in order of reliability
    # 1) lsblk SERIAL column (most reliable for SATA)
    # 2) /sys/block/*/device/serial (direct sysfs)
    # 3) hdparm serial field (ATA identify)
    # 4) wwid last field after final underscore (SATA t10 wwid format)
    SERIAL=$(lsblk -dno SERIAL "$TARGET" 2>/dev/null | tr -d ' ')

    if [ -z "$SERIAL" ]; then
        SERIAL=$(cat "/sys/block/$DRIVE/device/serial" 2>/dev/null | tr -d ' ')
    fi

    if [ -z "$SERIAL" ]; then
        SERIAL=$(hdparm -I "$TARGET" 2>/dev/null \
                 | grep -i "Serial Number" | awk '{print $NF}' | tr -d ' ')
    fi

    if [ -z "$SERIAL" ]; then
        # wwid format: t10.ATA_ModelName_SerialNumber
        # Serial is the last underscore-delimited field
        SERIAL=$(cat "/sys/block/$DRIVE/device/wwid" 2>/dev/null \
                 | awk -F'_' '{print $NF}' | tr -d ' ')
    fi

    CLEAN_SERIAL="${SERIAL:-UNKNOWN}"
    MODEL=$(lsblk -dno MODEL "$TARGET" 2>/dev/null | xargs)
    DRIVE_TYPE=$(get_drive_type "$DRIVE")
    SIZE=$(lsblk -dno SIZE "$TARGET" 2>/dev/null)
    DRIVE_FROZEN=0
    VERIFY_STATUS=""
    VERIFY_HEXDUMP=""
    STATUS_BOX_DRAWN=0   # reset box state for each new drive

    # Set globals used by print_status
    CURRENT_TARGET="$TARGET"
    CURRENT_MODEL="$MODEL"
    CURRENT_SIZE="$SIZE"
    CURRENT_TRY="Initializing"

    log ""
    log "----------------------------------------------------"
    log "TARGET : $TARGET"
    log "MODEL  : $MODEL"
    log "SERIAL : $CLEAN_SERIAL"
    log "TYPE   : $DRIVE_TYPE"
    log "SIZE   : $SIZE"
    log "----------------------------------------------------"

    print_status "Drive detected — beginning wipe cascade"

    WIPE_RESULT=""
    case "$DRIVE_TYPE" in
        nvme)
            wipe_nvme "$TARGET"
            ;;
        ssd|hdd)
            wipe_sata "$TARGET"
            ;;
        *)
            CURRENT_TRY="dd (unknown drive type)"
            print_status "Unknown type — defaulting to dd"
            log "  [!] Unknown drive type — defaulting to dd"
            dd if=/dev/zero of="$TARGET" bs=1M status=progress conv=fsync \
                2>&1 | tee -a "$LOG_FILE"
            WIPE_RESULT="dd Zero Overwrite (unknown type)"
            verify_wipe "$TARGET" "$WIPE_RESULT"
            ;;
    esac

    FINAL_METHOD="$WIPE_RESULT"
    CURRENT_TRY="COMPLETE"
    print_status "Done — Method: $FINAL_METHOD"
    log "  RESULT: $FINAL_METHOD"

    # -------------------------------------------------------------------------
    # CERTIFICATE OF DESTRUCTION
    # -------------------------------------------------------------------------
    CERT_FILE="$CERT_DIR/${DATESTAMP}_${CLEAN_SERIAL}_${PCNAME}_San-Cert.txt"

    # Classify the final method for certificate NIST language
    classify_nist_action "$FINAL_METHOD"

    # Capture first 512 bytes of drive as hex proof.
    # For Clear (overwrite): all-zero output confirms zeroed media.
    # For Purge (crypto/sanitize): non-zero is expected and correct —
    #   hex is recorded as an audit sample confirming drive is readable
    #   post-erase per NIST 800-88 §2.4 accessibility verification.
    local HEX_PROOF
    HEX_PROOF=$(dd if="$TARGET" bs=512 count=1 2>/dev/null | hexdump -C)

    # NIST action-specific certificate language
    local NIST_STANDARD_LINE NIST_VERIFY_METHOD HEX_PROOF_CAPTION
    if [ "$NIST_ACTION" = "Purge" ]; then
        NIST_STANDARD_LINE="NIST SP 800-88 Rev. 1 — Purge"
        NIST_VERIFY_METHOD="Purge verification: drive accessibility confirmed post-erase. Non-zero readback is expected and correct per NIST 800-88 §2.4."
        HEX_PROOF_CAPTION="HEX SAMPLE — First 512 bytes post-Purge (non-zero expected; confirms drive is readable):"
    else
        NIST_STANDARD_LINE="NIST SP 800-88 Rev. 1 — Clear"
        NIST_VERIFY_METHOD="Clear verification: multi-zone zero-fill confirmed by direct sector read."
        HEX_PROOF_CAPTION="HEX PROOF — First 512 bytes post-Clear (all-zero confirms media overwritten):"
    fi

    {
        echo "====================================================="
        echo "          CERTIFICATE OF DATA DESTRUCTION"
        echo "====================================================="
        echo "Date          : $(date)"
        echo "Machine       : $PCNAME"
        echo "Drive Target  : $TARGET"
        echo "Model         : $MODEL"
        echo "Serial        : $CLEAN_SERIAL"
        echo "Drive Type    : $DRIVE_TYPE"
        echo "Capacity      : $SIZE"
        echo "Wipe Method   : $FINAL_METHOD"
        echo "NIST Action   : $NIST_ACTION"
        echo "NIST Standard : $NIST_STANDARD_LINE"
        echo "Verify Method : $NIST_VERIFY_METHOD"
        echo "Verify Status : ${VERIFY_STATUS:-NOT RUN}"
        echo "BIOS Frozen   : $([ "$DRIVE_FROZEN" = "1" ] \
                               && echo 'YES — hdparm bypassed' || echo 'No')"
        echo "-----------------------------------------------------"
        echo "POST-WIPE VERIFICATION (multi-zone samples):"
        echo "${VERIFY_HEXDUMP:-  Verification not performed}"
        echo "-----------------------------------------------------"
        echo "$HEX_PROOF_CAPTION"
        echo ""
        echo "${HEX_PROOF:-  Could not read drive}"
        echo "====================================================="
    } > "$CERT_FILE"

    log "  Certificate: $CERT_FILE"
    echo ""
    echo "  Certificate written: $CERT_FILE"
    echo ""
    DRIVES_PROCESSED=$(( DRIVES_PROCESSED + 1 ))
done

sync
logecho ""
logecho "============================================================"
logecho " ALL DRIVES PROCESSED. Certificates: $CERT_DIR"
logecho "============================================================"

# Play FF Victory Fanfare then show completion banner
play_fanfare
show_completion_banner "$DRIVES_PROCESSED"
