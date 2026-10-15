#!/system/bin/sh
# F2FS GC stress/latency test for a dedicated test partition.
# Example:
# F2FS_IO=/data/required_bins/f2fs_io IMAGE_LABEL=with_offload ROUNDS=2 LEAVE_FREE_MB=96 sh /data/local/tmp/f2fs_gc_force_latency_known_content_verbose.sh /mnt/test /dev/block/sdg
#
# Fills according to actual free space, deletes alternating files, rewrites
# freed space, then invokes synchronous GC via `f2fs_io gc 1 <file>`.
# No script can guarantee GC moves a victim: that depends on F2FS segment state
# and policy. A successful ioctl does not prove blocks were migrated.
# This test deliberately writes substantial data to the test filesystem.

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
VERBOSE="${VERBOSE:-1}"
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
F2FS_TAG="${F2FS_TAG:-F2FS-fs (${DEVBASE})}"
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
new_duration_marker() {
  sed -n 's/.*GC_TIMING:.*duration_us=\([0-9][0-9]*\).*/\1/p' "$1" |
    awk -v skip="$2" 'NR > skip { value=$0 } END { if (value != "") print value }'
}
count_copy_success() { grep -c 'COPY_OFFLOAD_SUCCESS' "$1" 2>/dev/null; }

say() {
  [ "$VERBOSE" = 0 ] || echo "$*"
}

echo "============================================================"
echo "F2FS GC known-content / copy-offload test"
echo "Image       : $IMAGE_LABEL"
echo "Mount       : $MNT"
echo "Source      : $SRC"
echo "F2FS log tag: $F2FS_TAG"
echo "f2fs_io     : $F2FS_IO"
echo "Rounds      : $ROUNDS"
echo "Target file : $MIGRATION_LINES lines, copied in ${MIGRATION_CHUNK_KB} KiB chunks"
echo "Free reserve: ${LEAVE_FREE_MB} MiB; fill chunk: ${CHUNK_MB} MiB"
echo "Log dir     : $LOGDIR"
echo "CSV         : $RESULT_CSV"
echo "============================================================"

# Aggregates use GC_TIMING durations observed after each round. A round with
# no new marker is excluded from the average.
TOTAL_GC_US=0
VALID_GC_ROUNDS=0
TOTAL_COPY_SUCCESS=0
ROUNDS_WITH_COPY=0

R=1
while [ "$R" -le "$ROUNDS" ]; do
  echo
  echo "-------------------- ROUND $R/$ROUNDS --------------------"
  say "[stage 1/8] Preparing test directory: $BASE"
  rm -rf "$BASE" || exit 1
  mkdir -p "$BASE/fill" "$BASE/rewrite" "$BASE/spacers" || exit 1

  # Generate deterministic, recognizable content on /data (source filesystem),
  # then copy it to the F2FS test mount in small pieces with spacer allocations
  # between pieces. This encourages non-contiguous physical allocation of the
  # target file; it does NOT guarantee a particular victim segment is selected.
  say "[stage 2/8] Generating known-content source file on /data: $MIGRATION_SOURCE"
  : > "$MIGRATION_SOURCE" || { echo "ERROR: cannot create $MIGRATION_SOURCE"; exit 1; }
  LINE=1
  while [ "$LINE" -le "$MIGRATION_LINES" ]; do
    echo "F2FS_GC_MIGRATION_LINE=$LINE payload=known_content_for_gc_test" >> "$MIGRATION_SOURCE" || exit 1
    LINE=$((LINE + 1))
  done
  sync
  SRC_BYTES="$(wc -c < "$MIGRATION_SOURCE" | tr -d ' ')"
  say "  Source generated: lines=$MIGRATION_LINES bytes=$SRC_BYTES"
  say "[stage 3/8] Copying source to F2FS in ${MIGRATION_CHUNK_KB} KiB chunks, interleaving spacer allocations"
  : > "$MIGRATION_FILE" || exit 1
  CHUNK_BYTES=$((MIGRATION_CHUNK_KB * 1024))
  OFFSET=0
  PART=0
  while [ "$OFFSET" -lt "$SRC_BYTES" ]; do
    PART=$((PART + 1))
    if [ "$VERBOSE" != 0 ] && [ $((PART % 100)) -eq 1 ]; then
      say "  Copy progress: chunk $PART (offset=$OFFSET/$SRC_BYTES bytes)"
    fi
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
  TARGET_BYTES="$(wc -c < "$MIGRATION_FILE" | tr -d ' ')"
  say "  Target created: $MIGRATION_FILE bytes=$TARGET_BYTES chunks=$PART"
  say "[stage 4/8] Capturing baseline free space and F2FS GC timing-marker count"
  FB="$(free_kb)"
  target_dmesg > "$LOGDIR/before_${R}.log"
  OLD="$(count_markers "$LOGDIR/before_${R}.log")"; [ -n "$OLD" ] || OLD=0

  say "[stage 5/8] Filling filesystem while preserving approximately ${LEAVE_FREE_MB} MiB plus headroom"
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
      say "  Fill stopped at chunk $I (rc=$RC); keeping successfully allocated data."
      rm -f "$BASE/fill/chunk_${I}.bin"
      I=$((I - 1))
      break
    fi
  done
  sync
  say "  Fill complete: allocated_chunks=$I free_space_kib=$(free_kb)"

  say "[stage 6/8] Creating allocation churn: deleting alternating fill files and rewriting retained data"
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
      say "  Rewrite stopped at item $J (allocation failed / low free space)."; break;
    }
  done
  say "  Churn complete: rewrite_files_attempted=$J free_space_kib=$(free_kb)"
  say "[stage 7/8] Preparing synchronous GC request and recording pre-GC counters"
  echo "gc control; known migration content is $MIGRATION_FILE" > "$BASE/gc_control" || exit 1
  sync
  FGC="$(free_kb)"
  target_dmesg > "$LOGDIR/pre_gc_${R}.log"
  OLD="$(count_markers "$LOGDIR/pre_gc_${R}.log")"; [ -n "$OLD" ] || OLD=0
  OLD_COPY="$(count_copy_success "$LOGDIR/pre_gc_${R}.log")"; [ -n "$OLD_COPY" ] || OLD_COPY=0

  say "  Invoking: $F2FS_IO gc 1 $BASE/gc_control"
  START="$(uptime_s)"
  "$F2FS_IO" gc 1 "$BASE/gc_control" > "$LOGDIR/gc_ioctl_${R}.log" 2>&1
  RC=$?
  END="$(uptime_s)"
  GC_MS="$(awk -v s="$START" -v e="$END" 'BEGIN {printf "%.3f",(e-s)*1000}')"
  say "  ioctl exit status=$RC; wall-clock elapsed=${GC_MS} ms"
  if [ -s "$LOGDIR/gc_ioctl_${R}.log" ]; then
    say "  ioctl output:"
    sed 's/^/    /' "$LOGDIR/gc_ioctl_${R}.log"
  fi
  say "[stage 8/8] Waiting up to ${GC_WAIT_SEC}s for a new GC_TIMING marker and collecting F2FS logs"

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
  GUS="$(new_duration_marker "$LOGDIR/after_${R}.log" "$OLD")"
  [ -n "$GUS" ] || GUS=""
  COPY_AFTER="$(count_copy_success "$LOGDIR/after_${R}.log")"
  [ -n "$COPY_AFTER" ] || COPY_AFTER=0
  COPY_COUNT=$((COPY_AFTER - OLD_COPY))
  [ "$COPY_COUNT" -ge 0 ] || COPY_COUNT=0
  if [ "$DELTA" -gt 0 ] && [ -n "$GUS" ]; then
    TOTAL_GC_US=$((TOTAL_GC_US + GUS))
    VALID_GC_ROUNDS=$((VALID_GC_ROUNDS + 1))
  fi
  if [ "$COPY_COUNT" -gt 0 ]; then
    TOTAL_COPY_SUCCESS=$((TOTAL_COPY_SUCCESS + COPY_COUNT))
    ROUNDS_WITH_COPY=$((ROUNDS_WITH_COPY + 1))
  fi
  FA="$(free_kb)"
  TS="$(date +%Y-%m-%dT%H:%M:%S)"
  NOTE="sync_gc_ioctl"
  [ "$RC" -eq 0 ] || NOTE="sync_gc_ioctl_failed"
  [ "$DELTA" -gt 0 ] || NOTE="${NOTE};no_new_GC_TIMING_marker"
  echo "$TS,$IMAGE_LABEL,$MNT,$SRC,$R,$FB,$FGC,$FA,$I,$GC_MS,$GUS,$DELTA,$RC,$NOTE" >> "$RESULT_CSV"

  echo
  echo "Round $R result:"
  echo "  Free space (KiB) : before=$FB at_gc=$FGC after=$FA"
  echo "  GC ioctl         : rc=$RC wall_elapsed=${GC_MS} ms"
  echo "  GC timing        : new_markers=$DELTA last_duration_us=${GUS:-not-found}"
  echo "  Copy-offload     : COPY_OFFLOAD_SUCCESS log_count=$COPY_COUNT"
  echo "  Filtered logs    : $LOGDIR"
  say "  CSV row appended to $RESULT_CSV"
  if [ "$KEEP_FILES" != 1 ]; then rm -rf "$BASE"; sync; fi
  echo
  R=$((R + 1))
done
echo
echo "============================================================"
echo "FINAL SUMMARY"
echo "============================================================"
echo "Rounds requested                  : $ROUNDS"
echo "Rounds with a new GC_TIMING marker: $VALID_GC_ROUNDS"
if [ "$VALID_GC_ROUNDS" -gt 0 ]; then
  AVG_GC_US=$((TOTAL_GC_US / VALID_GC_ROUNDS))
  AVG_GC_MS="$(awk -v u="$TOTAL_GC_US" -v n="$VALID_GC_ROUNDS" 'BEGIN {printf "%.3f",u/n/1000}')"
  echo "Average GC duration               : ${AVG_GC_US} us (${AVG_GC_MS} ms)"
  echo "Total measured GC duration        : ${TOTAL_GC_US} us"
else
  echo "Average GC duration               : N/A (no valid new GC_TIMING markers)"
fi
echo "Rounds with copy-offload success  : $ROUNDS_WITH_COPY"
echo "Total COPY_OFFLOAD_SUCCESS logs   : $TOTAL_COPY_SUCCESS"
echo "CSV                               : $RESULT_CSV"
echo "Per-round logs                    : $LOGDIR"
echo "============================================================"
echo "Note: COPY_OFFLOAD_SUCCESS counts are based on F2FS-tagged dmesg lines captured after each GC request."
echo "============================================================"
