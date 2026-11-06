#!/system/bin/sh
# F2FS GC copy-offload A/B benchmark driver. WARNING: reformats $DEV every run.
# Usage: sh gcbench.sh            (all knobs are environment variables)
DEV=${DEV:-/dev/block/sdg}
BLK=${BLK:-sdg}
MNT=${MNT:-/mnt/gcbench}
BIN=${BIN:-/data/local/tmp/gcbench}
OUT=${OUT:-/data/local/tmp/gcbench_results}
MKFS=${MKFS:-"make_f2fs -f"}                 # use the same mkfs/options as common.sh
MOUNT_OPTS=${MOUNT_OPTS:-"background_gc=off"} # BG GC must be off for FG-ioctl runs
QNODE=${QNODE:-/sys/block/$BLK/queue/copy_offload}
CNODE=${CNODE:-/sys/fs/f2fs/$BLK/copy_offload_calls}
MOVED=${MOVED:-/sys/fs/f2fs/$BLK/moved_blocks_foreground}
NSEG=${NSEG:-4096}          # victim segments (2 MiB each) -> 8 GiB written
UNIT_KB=${UNIT_KB:-256}     # file size; 2048/UNIT_KB files per segment
KEEPS=${KEEPS:-"2 4 6"}     # valid files per segment (of 8 with UNIT_KB=256)
PATTERNS=${PATTERNS:-"contig alt"}
REPS=${REPS:-5}
FGIO=${FGIO:-0}             # 1 = concurrent foreground fsync-append writer
GOV=${GOV:-}                # e.g. performance
CSV=$OUT/results_$(date +%Y%m%d_%H%M%S).csv

mkdir -p "$OUT" "$MNT"
[ -x "$BIN" ] || { echo "missing $BIN"; exit 1; }
[ -w "$QNODE" ] || { echo "missing $QNODE"; exit 1; }
SAVED_PRINTK=$(cat /proc/sys/kernel/printk)
echo "1 1 1 1" > /proc/sys/kernel/printk 2>/dev/null
if [ -n "$GOV" ]; then
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$GOV" > "$g" 2>/dev/null; done
fi
trap 'echo "$SAVED_PRINTK" > /proc/sys/kernel/printk' EXIT

echo "mode,keep,pattern,rep,prep,gc_calls,gc_busy,last_errno,wall_ms,thread_cpu_ms,sys_cpu_ms,moved_blks,call_p50_us,call_p99_us,call_max_us,fg_ops,fg_p50_us,fg_p99_us,fg_max_us,offload_cmds,verify,bad" > "$CSV"

kv() { # kv key "line"  -> value
  echo "$2" | tr ' ' '\n' | grep "^$1=" | head -1 | cut -d= -f2
}

one_run() { # mode(on|off) keep pattern rep
  mode=$1; keep=$2; pat=$3; rep=$4
  v=0; [ "$mode" = on ] && v=1
  umount "$MNT" 2>/dev/null
  $MKFS "$DEV" >/dev/null 2>&1 || { echo "mkfs failed"; return 1; }
  mount -t f2fs -o "$MOUNT_OPTS" "$DEV" "$MNT" || { echo "mount failed"; return 1; }
  echo 0 > "$QNODE"                       # identical (CPU) layout work during prep
  P=$("$BIN" prep "$MNT" "$NSEG" "$UNIT_KB" "$keep" "$pat") || { echo "prep failed"; return 1; }
  sync
  umount "$MNT"; mount -t f2fs -o "$MOUNT_OPTS" "$DEV" "$MNT" || return 1
  echo 3 > /proc/sys/vm/drop_caches       # cold cache: the CPU path must really read
  sleep 5                                  # let background flush/discard settle
  echo "$v" > "$QNODE"
  C0=$(cat "$CNODE" 2>/dev/null); C0=${C0:-0}
  R=$("$BIN" run "$MNT" "$NSEG" "$MOVED" "$FGIO")
  C1=$(cat "$CNODE" 2>/dev/null); C1=${C1:-$C0}
  echo 0 > "$QNODE"
  sync; echo 3 > /proc/sys/vm/drop_caches
  V=$("$BIN" verify "$MNT" "$NSEG" "$UNIT_KB" "$keep" "$pat")
  echo "$mode keep=$keep pat=$pat rep=$rep :: $R :: $V"
  echo "$mode,$keep,$pat,$rep,$(kv kept_blocks "$P"),$(kv gc_calls "$R"),$(kv gc_busy "$R"),$(kv last_errno "$R"),$(kv wall_ms "$R"),$(kv thread_cpu_ms "$R"),$(kv sys_cpu_ms "$R"),$(kv moved_blks "$R"),$(kv call_p50_us "$R"),$(kv call_p99_us "$R"),$(kv call_max_us "$R"),$(kv fg_ops "$R"),$(kv fg_p50_us "$R"),$(kv fg_p99_us "$R"),$(kv fg_max_us "$R"),$((C1-C0)),$(kv verify "$V"),$(kv bad "$V")" >> "$CSV"
}

for pat in $PATTERNS; do
 for keep in $KEEPS; do
  rep=1
  while [ $rep -le $REPS ]; do
    # alternate which mode goes first to cancel drift (thermal, FTL state)
    if [ $((rep % 2)) -eq 1 ]; then first=on; second=off; else first=off; second=on; fi
    one_run $first  $keep $pat $rep
    one_run $second $keep $pat $rep
    rep=$((rep + 1))
  done
 done
done
umount "$MNT" 2>/dev/null
echo "done: $CSV"
