#!/system/bin/sh
# F2FS GC copy-offload A/B benchmark driver.
# WARNING: unless NO_MKFS=1, this REFORMATS $DEV before every run.
DEV=${DEV:-/dev/block/sdg}
BLK=${BLK:-${DEV##*/}}
MNT=${MNT:-/mnt/test}
BIN=${BIN:-/data/local/tmp/gcbench}
OUT=${OUT:-/data/local/tmp/gcbench_results}
MKFS=${MKFS:-"make_f2fs -f"}
NO_MKFS=${NO_MKFS:-0}       # 1 = never mkfs/mount; reuse the existing mount and just clean up
QNODE=${QNODE:-/sys/block/$BLK/queue/copy_offload}
CNODE=${CNODE:-/sys/fs/f2fs/$BLK/copy_offload_calls}
MOVED=${MOVED:-/sys/fs/f2fs/$BLK/moved_blocks_foreground}
NSEG=${NSEG:-4096}
UNIT_KB=${UNIT_KB:-256}
KEEPS=${KEEPS:-"2 4 6"}
PATTERNS=${PATTERNS:-"contig alt"}
REPS=${REPS:-5}
FGIO=${FGIO:-0}
GOV=${GOV:-}
CSV=$OUT/results_$(date +%Y%m%d_%H%M%S).csv

abort() { echo "ABORT: $*"; exit 1; }

mkdir -p "$OUT" || abort "cannot create $OUT"
[ -x "$BIN" ] || abort "missing/non-executable $BIN"
[ -w "$QNODE" ] || abort "cannot write $QNODE"

# Reuse the mount options the device already mounts this partition with
# (the way the existing suite's mount was done), but force BG GC off.
ORIG_OPTS=$(awk -v m="$MNT" '$2==m && $3=="f2fs"{print $4; exit}' /proc/mounts)
ORIG_SRC=$(awk -v m="$MNT" '$2==m && $3=="f2fs"{print $1; exit}' /proc/mounts)
if [ -z "$MOUNT_OPTS" ]; then
  base=$(echo "$ORIG_OPTS" | tr ',' '\n' | grep -v -E '^(seclabel|rw|ro|background_gc=.*)$' | tr '\n' ',' | sed 's/,$//')
  if [ -n "$base" ]; then MOUNT_OPTS="$base,background_gc=off"; else MOUNT_OPTS="background_gc=off"; fi
fi
if [ "$NO_MKFS" = 1 ]; then
  [ -n "$ORIG_SRC" ] || abort "NO_MKFS=1 but $MNT is not an f2fs mount"
  BGSTATE=$(echo "$ORIG_OPTS" | tr ',' '\n' | grep '^background_gc=')
  echo "NOTE: NO_MKFS=1 -> using existing mount ($BGSTATE). Disable BG GC yourself if it is on:"
  echo "      echo 0 > /sys/fs/f2fs/$BLK/gc_urgent ; mount -o remount,background_gc=off $MNT"
fi

echo "config: DEV=$DEV MNT=$MNT NO_MKFS=$NO_MKFS MKFS='$MKFS'"
echo "config: MOUNT_OPTS=$MOUNT_OPTS NSEG=$NSEG UNIT_KB=$UNIT_KB KEEPS='$KEEPS' PATTERNS='$PATTERNS' REPS=$REPS FGIO=$FGIO"

SAVED_PRINTK=$(cat /proc/sys/kernel/printk)
SAVED_QNODE=$(cat "$QNODE")
echo "1 1 1 1" > /proc/sys/kernel/printk 2>/dev/null
trap 'echo "$SAVED_PRINTK" > /proc/sys/kernel/printk 2>/dev/null; echo "$SAVED_QNODE" > "$QNODE" 2>/dev/null' EXIT
if [ -n "$GOV" ]; then
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo "$GOV" > "$g" 2>/dev/null; done
fi

echo "mode,keep,pattern,rep,prep,gc_calls,gc_busy,last_errno,wall_ms,thread_cpu_ms,sys_cpu_ms,moved_blks,call_p50_us,call_p99_us,call_max_us,fg_ops,fg_p50_us,fg_p99_us,fg_max_us,offload_cmds,verify,bad" > "$CSV"

kv() { echo "$2" | tr ' ' '\n' | grep "^$1=" | head -1 | cut -d= -f2; }

do_umount() {
  # unmount $MNT and any other mount of $DEV
  for m in $(awk -v d="$DEV" -v mp="$MNT" '$1==d || $2==mp {print $2}' /proc/mounts | sort -u); do
    umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null
  done
  sync
  awk -v d="$DEV" -v mp="$MNT" '$1==d || $2==mp {f=1} END{exit !f}' /proc/mounts && abort "cannot unmount $DEV/$MNT (busy). Stop the other suite first."
  return 0
}
do_mount() {
  mkdir -p "$MNT"
  out=$(mount -t f2fs -o "$MOUNT_OPTS" "$DEV" "$MNT" 2>&1) || abort "mount failed: $out | opts='$MOUNT_OPTS' (SELinux? try: setenforce 0, or pass -MountOpts)"
}

one_run() { # mode(on|off) keep pattern rep
  mode=$1; keep=$2; pat=$3; rep=$4
  v=0; [ "$mode" = on ] && v=1
  echo "--- run: $mode keep=$keep pat=$pat rep=$rep"
  if [ "$NO_MKFS" = 1 ]; then
    WORK=$MNT/gcbench_work
    rm -rf "$WORK"; sync
    mkdir -p "$WORK" || abort "cannot create $WORK"
  else
    do_umount
    out=$($MKFS "$DEV" 2>&1) || abort "mkfs failed: $out"
    do_mount
    WORK=$MNT
  fi
  echo 0 > "$QNODE"                        # identical (CPU) work during prep
  P=$("$BIN" prep "$WORK" "$NSEG" "$UNIT_KB" "$keep" "$pat" 2>&1) || abort "prep failed: $P"
  echo "prep: $P"
  sync
  if [ "$NO_MKFS" != 1 ]; then do_umount; do_mount; fi
  echo 3 > /proc/sys/vm/drop_caches        # cold cache: the CPU path must really read
  sleep 5
  echo "$v" > "$QNODE"
  C0=$(cat "$CNODE" 2>/dev/null); C0=${C0:-0}
  R=$("$BIN" run "$WORK" "$NSEG" "$MOVED" "$FGIO" 2>&1)
  C1=$(cat "$CNODE" 2>/dev/null); C1=${C1:-$C0}
  echo 0 > "$QNODE"
  echo "run: $R"
  sync; echo 3 > /proc/sys/vm/drop_caches
  V=$("$BIN" verify "$WORK" "$NSEG" "$UNIT_KB" "$keep" "$pat" 2>&1)
  echo "verify: $V"
  [ -n "$(kv gc_calls "$R")" ] || abort "gcbench run produced no result: $R"
  echo "$mode,$keep,$pat,$rep,$(kv kept_blocks "$P"),$(kv gc_calls "$R"),$(kv gc_busy "$R"),$(kv last_errno "$R"),$(kv wall_ms "$R"),$(kv thread_cpu_ms "$R"),$(kv sys_cpu_ms "$R"),$(kv moved_blks "$R"),$(kv call_p50_us "$R"),$(kv call_p99_us "$R"),$(kv call_max_us "$R"),$(kv fg_ops "$R"),$(kv fg_p50_us "$R"),$(kv fg_p99_us "$R"),$(kv fg_max_us "$R"),$((C1-C0)),$(kv verify "$V"),$(kv bad "$V")" >> "$CSV"
  if [ "$NO_MKFS" = 1 ]; then rm -rf "$WORK"; sync; fi
}

for pat in $PATTERNS; do
 for keep in $KEEPS; do
  rep=1
  while [ $rep -le $REPS ]; do
    if [ $((rep % 2)) -eq 1 ]; then first=on; second=off; else first=off; second=on; fi
    one_run $first  $keep $pat $rep
    one_run $second $keep $pat $rep
    rep=$((rep + 1))
  done
 done
done
[ "$NO_MKFS" = 1 ] || do_umount
echo "done: $CSV"
