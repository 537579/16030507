#!/system/bin/sh
# F2FS GC stress/latency test for a dedicated test partition.
# Example:
# F2FS_IO=/data/required_bins/f2fs_io IMAGE_LABEL=with_offload ROUNDS=2 LEAVE_FREE_MB=96 sh /data/local/tmp/f2fs_gc_force_latency.sh /mnt/test /dev/block/sdg
#
# Fills according to actual free space, deletes alternating files, rewrites
# freed space, then invokes synchronous GC via `f2fs_io gc 1 <file>`.
# No script can guarantee GC moves a victim: that depends on F2FS segment state
# and policy. A successful ioctl does not prove blocks were migrated.
# WARNING: use only on a disposable test partition; this writes most of it.

PATH=/system/bin:/system/xbin:/vendor/bin:/sbin:/bin
export PATH
MNT="${1:-}"
EXPECTED_DEV="${2:-}"
IMAGE_LABEL="${IMAGE_LABEL:-unspecified}"
ROUNDS="${ROUNDS:-2}"
LEAVE_FREE_MB="${LEAVE_FREE_MB:-96}"
CHUNK_MB="${CHUNK_MB:-16}"
GC_WAIT_SEC="${GC_WAIT_SEC:-30}"
RESULT_CSV="${RESULT_CSV:-/data/local/tmp/f2fs_gc_force_latency.csv}"
F2FS_IO="${F2FS_IO:-/data/required_bins/f2fs_io}"
KEEP_FILES="${KEEP_FILES:-0}"
MIGRATION_LINES="${MIGRATION_LINES:-1000}"
MIGRATION_CHUNK_KB="${MIGRATION_CHUNK_KB:-4}"
MIGRATION_SOURCE="${MIGRATION_SOURCE:-/data/local/tmp/f2fs_gc_migration_source.txt}"

[ "$(id -u)" = 0 ] || { echo "ERROR: run as root"; exit 1; }
[ -n "$MNT" ] && [ -d "$MNT" ] || { echo "Usage: $0 <f2fs-mountpoint> [expected-device]"; exit 2; }
SRC="$(awk -v m="$MNT" '$2 == m && $3 == "f2fs" {print $1; exit}' /proc/mounts)"
[ -n "$SRC" ] || { echo "ERROR: $MNT is not an exact F2FS mountpoint"; awk '$3=="f2fs"{print $1,$2}' /proc/mounts; exit 1; }
[ -z "$EXPECTED_DEV" ] || [ "${SRC##*/}" = "${EXPECTED_DEV##*/}" ] || {
  echo "ERROR: mount source '$SRC' does not match expected '$EXPECTED_DEV'"; exit 1;
}
[ -f "$F2FS_IO" ] && [ -x "$F2FS_IO" ] || { echo "ERROR: f2fs_io not executable: $F2FS_IO"; exit 1; }

case "$ROUNDS:$LEAVE_FREE_MB:$CHUNK_MB:$GC_WAIT_SEC:$MIGRATION_LINES:$MIGRATION_CHUNK_KB" in
  *[!0-9:]*|:*|*::*|*:) echo "ERROR: settings must be positive integers"; exit 2 ;;
esac
[ "$ROUNDS" -ge 1 ] && [ "$LEAVE_FREE_MB" -ge 16 ] && [ "$CHUNK_MB" -ge 1 ] && [ "$GC_WAIT_SEC" -ge 1 ] && [ "$MIGRATION_LINES" -ge 1000 ] && [ "$MIGRATION_CHUNK_KB" -ge 4 ] || exit 2

DEVBASE="${SRC##*/}"
F2FS_TAG="F2FS-fs (${DEVBASE})"
BASE="$MNT/.f2fs_gc_force_test"
MIGRATION_FILE="$BASE/migration_known_content.txt"
LOGDIR="/data/local/tmp/f2fs_gc_force_${DEVBASE}_${IMAGE_LABEL}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOGDIR" "$(dirname "$RESULT_CSV")" || exit 1
[ -f "$RESULT_CSV" ] || echo "timestamp,image,mountpoint,source,round,free_kb_before,free_kb_at_gc,free_kb_after,fill_chunks,gc_ioctl_ms,gc_marker_us,new_marker_count,ioctl_rc,notes" > "$RESULT_CSV"

free_kb() { df -k "$MNT" | awk 'NR==2 {print $4; exit}'; }
uptime_s() { awk '{print $1}' /proc/uptime; }
# Keep only this mounted filesystem's tagged F2FS messages. Generic [BLK_COPY]
# lines without an sdg/filesystem tag cannot safely be attributed to this mount.
target_dmesg() { dmesg 2>&1 | grep -F "$F2FS_TAG"; }
count_markers() { grep -c 'GC_TIMING:.*duration_us=' "$1" 2>/dev/null; }
duration_marker() { sed -n 's/.*GC_TIMING:.*duration_us=\([0-9][0-9]*\).*/\1/p' "$1" | tail -1; }

echo "Image=$IMAGE_LABEL mount=$MNT source=$SRC log_filter='$F2FS_TAG' f2fs_io=$F2FS_IO"
echo "Will generate a ${MIGRATION_LINES}-line known-content file on /data, fragment its copy on the test F2FS mount, then fill/churn and request synchronous GC."
echo "WARNING: only run on a disposable test partition."

R=1
while [ "$R" -le "$ROUNDS" ]; do
  echo "=== Round $R/$ROUNDS ==="
  rm -rf "$BASE" || exit 1
  mkdir -p "$BASE/fill" "$BASE/rewrite" "$BASE/spacers" || exit 1

  # Generate deterministic, recognizable content on /data (source filesystem),
  # then copy it to the F2FS test mount in small pieces with spacer allocations
  # between pieces. This encourages non-contiguous physical allocation of the
  # target file; it does NOT guarantee a particular victim segment is selected.
  : > "$MIGRATION_SOURCE" || { echo "ERROR: cannot create $MIGRATION_SOURCE"; exit 1; }
  LINE=1
  while [ "$LINE" -le "$MIGRATION_LINES" ]; do
    echo "F2FS_GC_MIGRATION_LINE=$LINE payload=known_content_for_gc_test" >> "$MIGRATION_SOURCE" || exit 1
    LINE=$((LINE + 1))
  done
  sync
  SRC_BYTES="$(wc -c < "$MIGRATION_SOURCE" | tr -d ' ')"
  echo "Generated source=$MIGRATION_SOURCE lines=$MIGRATION_LINES bytes=$SRC_BYTES"
  : > "$MIGRATION_FILE" || exit 1
  CHUNK_BYTES=$((MIGRATION_CHUNK_KB * 1024))
  OFFSET=0
  PART=0
  while [ "$OFFSET" -lt "$SRC_BYTES" ]; do
    PART=$((PART + 1))
    # Append one source chunk to the known-content destination file.
    dd if="$MIGRATION_SOURCE" bs=1 skip="$OFFSET" count="$CHUNK_BYTES" 2>/dev/null >> "$MIGRATION_FILE" || {
      echo "ERROR: failed copying source chunk $PART"; exit 1;
    }
    OFFSET=$((OFFSET + CHUNK_BYTES))
    # Allocate a spacer between target-file chunks, then remove it. The spacer
    # helps interleave segment allocations; F2FS may still co-locate blocks.
    if [ "$OFFSET" -lt "$SRC_BYTES" ]; then
      dd if=/dev/zero of="$BASE/spacers/spacer_${PART}.bin" bs=4096 count=8 conv=fsync >/dev/null 2>&1 || true
    fi
  done
  sync
  rm -f "$BASE/spacers"/spacer_*.bin
  sync
  echo "Created known-content target=$MIGRATION_FILE bytes=$(wc -c < "$MIGRATION_FILE" | tr -d ' ') chunks=$PART"
  FB="$(free_kb)"
  target_dmesg > "$LOGDIR/before_${R}.log"
  OLD="$(count_markers "$LOGDIR/before_${R}.log")"; [ -n "$OLD" ] || OLD=0

  I=0
  while :; do
    FREE="$(free_kb)"
    [ -n "$FREE" ] || { echo "ERROR: cannot read free space"; exit 1; }
    # Keep reserve plus one chunk and ~8 MiB headroom for metadata.
    [ "$FREE" -gt $((LEAVE_FREE_MB * 1024 + CHUNK_MB * 1024 + 8192)) ] || break
    I=$((I + 1))
    dd if=/dev/zero of="$BASE/fill/chunk_${I}.bin" bs=1M count="$CHUNK_MB" conv=fsync > "$LOGDIR/fill_${R}_${I}.log" 2>&1
    RC=$?
    if [ "$RC" -ne 0 ]; then
      echo "Fill stopped at chunk $I (rc=$RC); continuing with allocated data."
      rm -f "$BASE/fill/chunk_${I}.bin"
      I=$((I - 1))
      break
    fi
  done
  sync
  echo "Allocated $I chunks; free space now $(free_kb) KiB"

  # Preserve migration_known_content.txt while deleting alternating bulk-fill chunks.
  # Delete every other chunk, then rewrite roughly the same amount into newly
  # allocated files to increase allocation churn/fragmentation.
  N=0
  for f in "$BASE"/fill/chunk_*.bin; do
    [ -f "$f" ] || continue
    N=$((N + 1))
    [ $((N % 2)) -eq 1 ] && rm -f "$f"
  done
  sync
  J=0
  for f in "$BASE"/fill/chunk_*.bin; do
    [ -f "$f" ] || continue
    J=$((J + 1))
    dd if=/dev/zero of="$BASE/rewrite/rewrite_${J}.bin" bs=1M count="$CHUNK_MB" conv=fsync > "$LOGDIR/rewrite_${R}_${J}.log" 2>&1 || {
      echo "Rewrite stopped at item $J (low free space)"; break;
    }
  done
  echo "gc control; known migration content is $MIGRATION_FILE" > "$BASE/gc_control" || exit 1
  sync
  FGC="$(free_kb)"
  target_dmesg > "$LOGDIR/pre_gc_${R}.log"
  OLD="$(count_markers "$LOGDIR/pre_gc_${R}.log")"; [ -n "$OLD" ] || OLD=0

  START="$(uptime_s)"
  "$F2FS_IO" gc 1 "$BASE/gc_control" > "$LOGDIR/gc_ioctl_${R}.log" 2>&1
  RC=$?
  END="$(uptime_s)"
  GC_MS="$(awk -v s="$START" -v e="$END" 'BEGIN {printf "%.3f",(e-s)*1000}')"
  cat "$LOGDIR/gc_ioctl_${R}.log"

  T=0
  while [ "$T" -lt "$GC_WAIT_SEC" ]; do
    target_dmesg > "$LOGDIR/poll_${R}.log"
    NC="$(count_markers "$LOGDIR/poll_${R}.log")"; [ -n "$NC" ] || NC=0
    [ "$NC" -gt "$OLD" ] && break
    sleep 1
    T=$((T + 1))
  done
  target_dmesg > "$LOGDIR/after_${R}.log"
  NEW="$(count_markers "$LOGDIR/after_${R}.log")"; [ -n "$NEW" ] || NEW=0
  DELTA=$((NEW - OLD)); [ "$DELTA" -ge 0 ] || DELTA=0
  GUS="$(duration_marker "$LOGDIR/after_${R}.log")"
  FA="$(free_kb)"
  TS="$(date +%Y-%m-%dT%H:%M:%S)"
  NOTE="sync_gc_ioctl"
  [ "$RC" -eq 0 ] || NOTE="sync_gc_ioctl_failed"
  [ "$DELTA" -gt 0 ] || NOTE="${NOTE};no_new_GC_TIMING_marker"
  echo "$TS,$IMAGE_LABEL,$MNT,$SRC,$R,$FB,$FGC,$FA,$I,$GC_MS,$GUS,$DELTA,$RC,$NOTE" >> "$RESULT_CSV"

  echo "Free KiB before=$FB at_gc=$FGC after=$FA"
  echo "Synchronous GC ioctl elapsed=${GC_MS} ms (not pure CPU time)"
  echo "New GC_TIMING markers=$DELTA; last duration_us=${GUS:-not-found}"
  echo "Filtered logs: $LOGDIR"
  if [ "$KEEP_FILES" != 1 ]; then rm -rf "$BASE"; sync; fi
  echo
  R=$((R + 1))
done
echo "CSV: $RESULT_CSV"
echo "Only '$F2FS_TAG' messages are stored in per-round dmesg logs. Override F2FS_TAG if the kernel uses a different F2FS log identifier."
echo "GC cannot be guaranteed if F2FS has no eligible victim; verify GC/migration markers."
