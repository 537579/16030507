#!/system/bin/sh
# F2FS GC latency benchmark. Run as root:
# IMAGE_LABEL=with_offload sh f2fs_gc_latency.sh /data
#
# Requires kernel instrumentation in the GC path that emits:
#   GC_TIMING: duration_us=<integer>
# The gc_urgent sysfs trigger is asynchronous. Trigger-to-marker time is NOT
# GC execution latency; duration_us is the actual instrumented GC-path duration.

PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:/bin
export PATH
MNT="${1:-}"
IMAGE_LABEL="${IMAGE_LABEL:-unspecified}"
ROUNDS="${ROUNDS:-3}"
FILE_MB="${FILE_MB:-32}"
CHURN_FILES="${CHURN_FILES:-8}"
GC_WAIT_SEC="${GC_WAIT_SEC:-120}"
RESULT_CSV="${RESULT_CSV:-/data/local/tmp/f2fs_gc_latency.csv}"
F2FS_SYSFS="${F2FS_SYSFS:-}"

[ "$(id -u)" = 0 ] || { echo "ERROR: run as root"; exit 1; }
[ -n "$MNT" ] && [ -d "$MNT" ] || { echo "Usage: IMAGE_LABEL=with_offload sh $0 <f2fs-mountpoint>"; exit 2; }
FS_TYPE="$(awk -v m="$MNT" '$2 == m {print $3; exit}' /proc/mounts)"
[ "$FS_TYPE" = f2fs ] || { echo "ERROR: $MNT is not an exact F2FS mountpoint"; grep ' f2fs ' /proc/mounts; exit 1; }

case "$ROUNDS:$FILE_MB:$CHURN_FILES:$GC_WAIT_SEC" in
  *[!0-9:]*|:*|*::*|*:) echo "ERROR: settings must be positive integers"; exit 2 ;;
esac
[ "$ROUNDS" -ge 1 ] && [ "$FILE_MB" -ge 1 ] && [ "$CHURN_FILES" -ge 2 ] && [ "$GC_WAIT_SEC" -ge 1 ] || exit 2

if [ -z "$F2FS_SYSFS" ]; then
  for d in /sys/fs/f2fs/*; do
    [ -w "$d/gc_urgent" ] || continue
    F2FS_SYSFS="$d"
    break
  done
fi
[ -n "$F2FS_SYSFS" ] && [ -w "$F2FS_SYSFS/gc_urgent" ] || {
  echo "ERROR: writable gc_urgent not found. Check /sys/fs/f2fs/*/gc_urgent"
  echo "Set F2FS_SYSFS=/sys/fs/f2fs/<matching-device> if multiple F2FS mounts exist."
  exit 1
}

BASE="$MNT/f2fs_gc_latency_workload"
LOGDIR="/data/local/tmp/f2fs_gc_latency_${IMAGE_LABEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOGDIR" "$(dirname "$RESULT_CSV")" || exit 1
[ -f "$RESULT_CSV" ] || echo "timestamp,image,mountpoint,round,gc_duration_us,trigger_to_marker_seconds,marker_found,notes" > "$RESULT_CSV"

uptime_s() { awk '{print $1}' /proc/uptime; }
get_dmesg() { dmesg 2>&1; }
extract_duration() { sed -n 's/.*GC_TIMING:.*duration_us=\\([0-9][0-9]*\\).*/\\1/p' "$1" | tail -1; }

echo "Image=$IMAGE_LABEL mount=$MNT sysfs=$F2FS_SYSFS"
echo "Kernel must emit GC_TIMING: duration_us=<integer> from the GC execution path."
echo "gc_urgent is asynchronous; trigger-to-marker is reported separately."
R=1
while [ "$R" -le "$ROUNDS" ]; do
  echo "=== Round $R/$ROUNDS ==="
  rm -rf "$BASE" || exit 1
  mkdir -p "$BASE" || exit 1
  sync
  get_dmesg > "$LOGDIR/before_$R.txt"
  OLD_COUNT="$(grep -c 'GC_TIMING:.*duration_us=' "$LOGDIR/before_$R.txt" 2>/dev/null)"
  [ -n "$OLD_COUNT" ] || OLD_COUNT=0

  # Write/delete/rewrite churn encourages fragmentation but does not guarantee GC.
  I=1
  while [ "$I" -le "$CHURN_FILES" ]; do
    dd if=/dev/zero of="$BASE/file$I" bs=1M count="$FILE_MB" conv=fsync > "$LOGDIR/write_${R}_${I}.txt" 2>&1 || {
      echo "ERROR writing workload; see $LOGDIR/write_${R}_${I}.txt"; exit 1; }
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
    dd if=/dev/zero of="$BASE/rewrite$I" bs=1M count="$FILE_MB" conv=fsync > "$LOGDIR/rewrite_${R}_${I}.txt" 2>&1 || {
      echo "ERROR rewriting workload; see $LOGDIR/rewrite_${R}_${I}.txt"; exit 1; }
    I=$((I + 1))
  done
  sync

  START="$(uptime_s)"
  echo 1 > "$F2FS_SYSFS/gc_urgent" || { echo "ERROR writing gc_urgent"; exit 1; }
  FOUND=0
  T=0
  GC_US=""
  while [ "$T" -lt "$GC_WAIT_SEC" ]; do
    get_dmesg > "$LOGDIR/poll_${R}.txt"
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
    echo "$TS,$IMAGE_LABEL,$MNT,$R,$GC_US,$TRIGGER_SEC,yes,kernel_GC_TIMING_marker" >> "$RESULT_CSV"
    echo "GC execution duration: ${GC_US} us"
    echo "Trigger-to-marker: ${TRIGGER_SEC} s (not GC execution duration)"
  else
    echo "$TS,$IMAGE_LABEL,$MNT,$R,,,no,no_new_GC_TIMING_marker" >> "$RESULT_CSV"
    echo "No new GC_TIMING marker within ${GC_WAIT_SEC}s. GC may not have run or instrumentation is missing."
  fi
  get_dmesg > "$LOGDIR/after_$R.txt"
  rm -rf "$BASE"
  sync
  echo "Kernel logs: $LOGDIR"
  R=$((R + 1))
done
echo "Done. Results: $RESULT_CSV"
echo "Repeat with the same settings on the other image and comparable filesystem state."
