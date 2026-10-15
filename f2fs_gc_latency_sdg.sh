#!/system/bin/sh
# F2FS GC latency benchmark for a specific F2FS mountpoint.
# Example:
# IMAGE_LABEL=with_offload F2FS_SYSFS=/sys/fs/f2fs/sdg ROUNDS=3 FILE_MB=48 CHURN_FILES=8 sh /data/local/tmp/f2fs_gc_latency_sdg.sh /mnt/test
# Requires kernel logs: GC_TIMING: duration_us=<integer>
# gc_urgent is asynchronous; trigger-to-marker time is not GC execution latency.

PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:/bin
export PATH
MNT="${1:-}"
IMAGE_LABEL="${IMAGE_LABEL:-unspecified}"
ROUNDS="${ROUNDS:-3}"
FILE_MB="${FILE_MB:-48}"
CHURN_FILES="${CHURN_FILES:-8}"
GC_WAIT_SEC="${GC_WAIT_SEC:-120}"
RESULT_CSV="${RESULT_CSV:-/data/local/tmp/f2fs_gc_latency.csv}"
F2FS_SYSFS="${F2FS_SYSFS:-}"
KEEP_FILES="${KEEP_FILES:-0}"

[ "$(id -u)" = 0 ] || { echo "ERROR: run as root"; exit 1; }
[ -n "$MNT" ] && [ -d "$MNT" ] || { echo "Usage: $0 <f2fs-mountpoint>"; exit 2; }

SRC="$(awk -v m="$MNT" '$2 == m && $3 == "f2fs" {print $1; exit}' /proc/mounts)"
[ -n "$SRC" ] || { echo "ERROR: $MNT is not an exact F2FS mountpoint"; awk '$3=="f2fs"{print $1,$2}' /proc/mounts; exit 1; }
SRCBASE="${SRC##*/}"

# Never fall back to the first sysfs entry. Match mount source basename.
if [ -z "$F2FS_SYSFS" ]; then
    CANDIDATE="/sys/fs/f2fs/$SRCBASE"
    [ -e "$CANDIDATE/gc_urgent" ] && F2FS_SYSFS="$CANDIDATE"
fi
[ -n "$F2FS_SYSFS" ] && [ -e "$F2FS_SYSFS/gc_urgent" ] || {
    echo "ERROR: no gc_urgent for mount source $SRC."
    echo "Available: "; ls -ld /sys/fs/f2fs/*/gc_urgent 2>/dev/null
    echo "Specify F2FS_SYSFS=/sys/fs/f2fs/<directory matching $SRCBASE>"
    exit 1
}
[ -w "$F2FS_SYSFS/gc_urgent" ] || { echo "ERROR: $F2FS_SYSFS/gc_urgent not writable"; exit 1; }

case "$ROUNDS:$FILE_MB:$CHURN_FILES:$GC_WAIT_SEC" in
  *[!0-9:]*|:*|*::*|*:) echo "ERROR: settings must be positive integers"; exit 2 ;;
esac
[ "$ROUNDS" -ge 1 ] && [ "$FILE_MB" -ge 1 ] && [ "$CHURN_FILES" -ge 2 ] && [ "$GC_WAIT_SEC" -ge 1 ] || exit 2

BASE="$MNT/f2fs_gc_latency_workload"
LOGDIR="/data/local/tmp/f2fs_gc_latency_${IMAGE_LABEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOGDIR" "$(dirname "$RESULT_CSV")" || exit 1
[ -f "$RESULT_CSV" ] || echo "timestamp,image,mountpoint,mount_source,sysfs,round,gc_duration_us,trigger_to_marker_seconds,marker_found,notes" > "$RESULT_CSV"
uptime_s() { awk '{print $1}' /proc/uptime; }
capture_dmesg() { dmesg 2>&1; }
extract_duration() { sed -n 's/.*GC_TIMING:.*duration_us=\([0-9][0-9]*\).*/\1/p' "$1" | tail -1; }

echo "Image=$IMAGE_LABEL mount=$MNT source=$SRC sysfs=$F2FS_SYSFS"
echo "Workload: $CHURN_FILES files x ${FILE_MB} MiB, delete alternating files, then rewrite."
echo "This writes substantial data to the test partition. GC is not guaranteed."
echo

R=1
while [ "$R" -le "$ROUNDS" ]; do
    echo "=== Round $R/$ROUNDS ==="
    rm -rf "$BASE" || exit 1
    mkdir -p "$BASE" || exit 1
    sync

    I=1
    while [ "$I" -le "$CHURN_FILES" ]; do
        dd if=/dev/zero of="$BASE/file$I" bs=1M count="$FILE_MB" conv=fsync > "$LOGDIR/write_${R}_${I}.txt" 2>&1 || { echo "Write failed; see $LOGDIR/write_${R}_${I}.txt"; exit 1; }
        I=$((I + 1))
    done
    I=1
    while [ "$I" -le "$CHURN_FILES" ]; do
        [ $((I % 2)) -eq 1 ] && rm -f "$BASE/file$I"
        I=$((I + 1))
    done
    sync
    I=1
    while [ "$I" -le "$CHURN_FILES" ]; do
        dd if=/dev/zero of="$BASE/rewrite$I" bs=1M count="$FILE_MB" conv=fsync > "$LOGDIR/rewrite_${R}_${I}.txt" 2>&1 || { echo "Rewrite failed; see $LOGDIR/rewrite_${R}_${I}.txt"; exit 1; }
        I=$((I + 1))
    done
    sync

    # Count markers immediately before trigger; workload itself may have run GC.
    capture_dmesg > "$LOGDIR/pre_trigger_${R}.txt"
    OLD_COUNT="$(grep -c 'GC_TIMING:.*duration_us=' "$LOGDIR/pre_trigger_${R}.txt" 2>/dev/null)"
    [ -n "$OLD_COUNT" ] || OLD_COUNT=0

    START="$(uptime_s)"
    echo 1 > "$F2FS_SYSFS/gc_urgent" || { echo "Failed to trigger $F2FS_SYSFS/gc_urgent"; exit 1; }
    FOUND=0
    T=0
    while [ "$T" -lt "$GC_WAIT_SEC" ]; do
        capture_dmesg > "$LOGDIR/poll_${R}.txt"
        NEW_COUNT="$(grep -c 'GC_TIMING:.*duration_us=' "$LOGDIR/poll_${R}.txt" 2>/dev/null)"
        [ -n "$NEW_COUNT" ] || NEW_COUNT=0
        if [ "$NEW_COUNT" -gt "$OLD_COUNT" ]; then
            GC_US="$(extract_duration "$LOGDIR/poll_${R}.txt")"
            END="$(uptime_s)"
            TRIGGER_SEC="$(awk -v s="$START" -v e="$END" 'BEGIN {printf "%.3f", e-s}')"
            FOUND=1
            break
        fi
        sleep 1
        T=$((T + 1))
    done

    TS="$(date +%Y-%m-%dT%H:%M:%S)"
    if [ "$FOUND" -eq 1 ] && [ -n "$GC_US" ]; then
        echo "$TS,$IMAGE_LABEL,$MNT,$SRC,$F2FS_SYSFS,$R,$GC_US,$TRIGGER_SEC,yes,kernel_GC_TIMING_marker" >> "$RESULT_CSV"
        echo "GC execution duration: ${GC_US} us"
        echo "Trigger-to-marker: ${TRIGGER_SEC} s (not GC execution duration)"
    else
        echo "$TS,$IMAGE_LABEL,$MNT,$SRC,$F2FS_SYSFS,$R,,,no,no_new_marker_or_GC_not_triggered" >> "$RESULT_CSV"
        echo "No new GC_TIMING marker within ${GC_WAIT_SEC}s; inspect $LOGDIR/pre_trigger_${R}.txt and poll_${R}.txt"
    fi
    capture_dmesg > "$LOGDIR/after_${R}.txt"
    [ "$KEEP_FILES" = 1 ] || { rm -rf "$BASE"; sync; }
    echo "Logs: $LOGDIR"
    R=$((R + 1))
done
echo "Done. CSV: $RESULT_CSV"
