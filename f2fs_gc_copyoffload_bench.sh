#!/system/bin/sh
#
# F2FS GC copy-offload A/B benchmark (Android device-side)
#
# Run this same script on the image WITH copy-offload and the image WITHOUT it.
# Run as root. Example:
#   adb push f2fs_gc_copyoffload_bench.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/f2fs_gc_copyoffload_bench.sh /data'
#
# Optional environment variables:
#   IMAGE_LABEL=with_offload | without_offload
#   FILE_COUNT=8              Number of initial files (default 8)
#   FILE_MB=10                Size of each initial file in MiB (default 10)
#   REPLACEMENT_COUNT=4       Number of replacement files (default 4)
#   REPEAT=3                  Number of measured rounds (default 3)
#   RESULT_CSV=/data/local/tmp/f2fs_gc_copyoffload_results.csv
#   KEEP_FILES=0              Delete test files after each round (default 0)
#
# IMPORTANT:
# This measures the elapsed time of a repeatable fragmentation/write workload,
# not isolated GC execution time. Correlate results with kernel GC/offload logs.
# Use the same mountpoint, free-space state, workload settings, thermal state,
# and run count for both images.

PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:/bin
export PATH

MNT="${1:-}"
if [ -z "$MNT" ]; then
    echo "Usage: IMAGE_LABEL=with_offload $0 <f2fs-mountpoint>"
    echo "Example: IMAGE_LABEL=with_offload $0 /data"
    exit 2
fi

IMAGE_LABEL="${IMAGE_LABEL:-unspecified}"
FILE_COUNT="${FILE_COUNT:-8}"
FILE_MB="${FILE_MB:-10}"
REPLACEMENT_COUNT="${REPLACEMENT_COUNT:-4}"
REPEAT="${REPEAT:-3}"
RESULT_CSV="${RESULT_CSV:-/data/local/tmp/f2fs_gc_copyoffload_results.csv}"
KEEP_FILES="${KEEP_FILES:-0}"

case "$FILE_COUNT:$FILE_MB:$REPLACEMENT_COUNT:$REPEAT" in
    *[!0-9:]*|:*|*::*|*:) echo "Invalid numeric benchmark setting"; exit 2 ;;
esac
if [ "$FILE_COUNT" -lt 2 ] || [ "$FILE_MB" -lt 1 ] ||
   [ "$REPLACEMENT_COUNT" -lt 1 ] || [ "$REPEAT" -lt 1 ]; then
    echo "FILE_COUNT >= 2, FILE_MB >= 1, REPLACEMENT_COUNT >= 1, REPEAT >= 1 required"
    exit 2
fi

if [ "$(id -u)" != "0" ]; then
    echo "ERROR: run as root (for example, adb shell su -c 'sh ...')."
    exit 1
fi
if [ ! -d "$MNT" ]; then
    echo "ERROR: mountpoint does not exist: $MNT"
    exit 1
fi

FS_TYPE="$(awk -v m="$MNT" '$2 == m {print $3; exit}' /proc/mounts)"
if [ "$FS_TYPE" != "f2fs" ]; then
    echo "ERROR: $MNT is not an exact mountpoint reported as F2FS (found: ${FS_TYPE:-unknown})."
    echo "Mountpoint entries:"
    grep " f2fs " /proc/mounts
    exit 1
fi

BASE="$MNT/f2fs_gc_copyoffload_bench"
LOGDIR="/data/local/tmp/f2fs_gc_copyoffload_${IMAGE_LABEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOGDIR" || exit 1
mkdir -p "$(dirname "$RESULT_CSV")" || exit 1

if [ ! -f "$RESULT_CSV" ]; then
    echo "timestamp,image,mountpoint,round,file_count,file_mb,replacement_count,workload_seconds,free_bytes_before,free_bytes_after,offload_log_lines,gc_log_lines,notes" > "$RESULT_CSV"
fi

now_seconds() {
    awk '{print $1}' /proc/uptime
}

free_bytes() {
    df -k "$MNT" | awk 'NR==2 {print $4 * 1024; exit}'
}

echo "Image label       : $IMAGE_LABEL"
echo "Mountpoint        : $MNT (F2FS)"
echo "Initial workload  : $FILE_COUNT files x ${FILE_MB} MiB"
echo "Replacement files : $REPLACEMENT_COUNT"
echo "Rounds            : $REPEAT"
echo "Result CSV        : $RESULT_CSV"
echo "Logs              : $LOGDIR"
echo "NOTE: This is workload elapsed time, not isolated GC latency."
echo

ROUND=1
while [ "$ROUND" -le "$REPEAT" ]; do
    echo "=== Round $ROUND/$REPEAT ==="

    # Remove only this script's previous test directory, then establish a
    # consistent starting point before timing.
    rm -rf "$BASE" || exit 1
    mkdir -p "$BASE" || exit 1
    sync

    FB="$(free_bytes)"
    dmesg > "$LOGDIR/dmesg_before_round${ROUND}.txt" 2>&1

    START="$(now_seconds)"

    # Create sequential files. conv=fsync makes each file's data durable before
    # moving to the next file, reducing ambiguity from delayed writeback.
    I=1
    while [ "$I" -le "$FILE_COUNT" ]; do
        dd if=/dev/zero of="$BASE/file${I}.bin" bs=1M count="$FILE_MB" conv=fsync \
            > "$LOGDIR/dd_create_r${ROUND}_f${I}.txt" 2>&1
        RC=$?
        if [ "$RC" -ne 0 ]; then
            echo "ERROR: initial file creation failed (round=$ROUND file=$I rc=$RC)"
            cat "$LOGDIR/dd_create_r${ROUND}_f${I}.txt"
            exit 1
        fi
        I=$((I + 1))
    done

    # Delete alternating files to create holes in the test workload.
    I=1
    while [ "$I" -le "$FILE_COUNT" ]; do
        if [ $((I % 2)) -eq 1 ]; then
            rm -f "$BASE/file${I}.bin" || exit 1
        fi
        I=$((I + 1))
    done
    sync

    # Write replacement files into the freed space. This is intended to create
    # allocation pressure/fragmentation; whether it triggers GC depends on
    # filesystem free space, segment state, and device configuration.
    I=1
    while [ "$I" -le "$REPLACEMENT_COUNT" ]; do
        dd if=/dev/zero of="$BASE/replacement${I}.bin" bs=1M count="$FILE_MB" conv=fsync \
            > "$LOGDIR/dd_replace_r${ROUND}_f${I}.txt" 2>&1
        RC=$?
        if [ "$RC" -ne 0 ]; then
            echo "ERROR: replacement file creation failed (round=$ROUND file=$I rc=$RC)"
            cat "$LOGDIR/dd_replace_r${ROUND}_f${I}.txt"
            exit 1
        fi
        I=$((I + 1))
    done

    sync
    END="$(now_seconds)"
    FA="$(free_bytes)"
    dmesg > "$LOGDIR/dmesg_after_round${ROUND}.txt" 2>&1

    ELAPSED="$(awk -v s="$START" -v e="$END" 'BEGIN {printf "%.3f", e-s}')"

    # Save full kernel snapshots. These counts are hints only: dmesg is a ring
    # buffer, and exact matching depends on the debug strings in the build.
    OFFLOAD_LINES="$(grep -Eic 'BLK_COPY|copy.offload|copy_offload|GC.*offload|offload.*GC' "$LOGDIR/dmesg_after_round${ROUND}.txt" 2>/dev/null)"
    GC_LINES="$(grep -Eic 'f2fs.*gc|gc.*f2fs|do_garbage_collect|f2fs_gc' "$LOGDIR/dmesg_after_round${ROUND}.txt" 2>/dev/null)"
    [ -n "$OFFLOAD_LINES" ] || OFFLOAD_LINES=0
    [ -n "$GC_LINES" ] || GC_LINES=0

    TS="$(date +%Y-%m-%dT%H:%M:%S)"
    echo "$TS,$IMAGE_LABEL,$MNT,$ROUND,$FILE_COUNT,$FILE_MB,$REPLACEMENT_COUNT,$ELAPSED,$FB,$FA,$OFFLOAD_LINES,$GC_LINES,workload_elapsed_not_isolated_gc" >> "$RESULT_CSV"

    echo "Elapsed workload time : ${ELAPSED} s"
    echo "Free bytes before     : ${FB:-unknown}"
    echo "Free bytes after      : ${FA:-unknown}"
    echo "Matching offload logs : $OFFLOAD_LINES (snapshot count; inspect logs)"
    echo "Matching GC logs      : $GC_LINES (snapshot count; inspect logs)"
    echo "Kernel log snapshot   : $LOGDIR/dmesg_after_round${ROUND}.txt"

    if [ "$KEEP_FILES" = "0" ]; then
        rm -rf "$BASE"
        sync
    fi
    echo
    ROUND=$((ROUND + 1))
done

echo "Benchmark complete."
echo "CSV results: $RESULT_CSV"
echo "Log directory: $LOGDIR"
echo
echo "For the other image, use the same script/settings and a distinct IMAGE_LABEL."
echo "Do not compare runs unless mountpoint, available space, workload, and test conditions match."
