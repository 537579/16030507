#!/system/bin/sh
# Shared helpers for the F2FS GC suite. POSIX sh only (Android mksh + toybox).
#
# Environment knobs (all optional):
#   SUITE_DIR    where the suite lives on device   (default /data/local/tmp/f2fs_gc_suite)
#   MNT          f2fs mount under test             (default /data)
#   TEST_DIR     scratch dir on that mount         (default $MNT/gctest)
#   MODE         result label: offload_off|offload_on (set by run_all.sh)
#   FILL_PCT     base utilisation for aging tests  (default 80)
#   SCALE_PCT    scales durations/sizes, 100=full  (default 100; 10 for a smoke run)
#   COPY_OFFLOAD_CTL      writable sysfs knob for copy offload (autodetected if unset)
#   COPY_OFFLOAD_ON_VAL / COPY_OFFLOAD_OFF_VAL   values written (default 1 / 0)

SUITE_DIR=${SUITE_DIR:-/data/local/tmp/f2fs_gc_suite}
MNT=${MNT:-/data}
TEST_DIR=${TEST_DIR:-$MNT/gctest}
MODE=${MODE:-offload_off}
RES_DIR=${RES_DIR:-$SUITE_DIR/results/$MODE}
GCLOAD=${GCLOAD:-$SUITE_DIR/gcload}
FILL_PCT=${FILL_PCT:-80}
SCALE_PCT=${SCALE_PCT:-100}
DBGFS=${DBGFS:-/sys/kernel/debug/f2fs/status}
CSV=$RES_DIR/results.csv
                                                                                                                                                                                                                                                                                                                                                                        
mkdir -p "$RES_DIR"
[ -f "$CSV" ] || echo "mode,test,metric,value,unit" > "$CSV"

log() { echo "[$(date +%H:%M:%S)] $*"; }
now_ms() {
  awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime
}
scale() { echo $(( $1 * SCALE_PCT / 100 )); }          # scale an integer
scale_min1() { v=$(scale "$1"); [ "$v" -lt 1 ] && v=1; echo "$v"; }

# ---------- device / sysfs discovery ----------
mnt_src() { awk -v m="$MNT" '$2==m && $3=="f2fs" {s=$1} END{print s}' /proc/mounts; }
blk_node() { s=$(mnt_src); echo "${s##*/}"; }

f2fs_node() {
  src=$(mnt_src)

  if [ -z "$src" ]; then
    echo "ERROR: $MNT is not mounted as F2FS" >&2
    return 1
  fi

  bn=${src##*/}

  if [ -d "/sys/fs/f2fs/$bn" ]; then
    echo "$bn"
    return 0
  fi

  echo "ERROR: Cannot map mount source $src to /sys/fs/f2fs" >&2
  echo "Set F2FS_NODE explicitly after verifying the correct instance." >&2
  return 1
}

F2FS_NODE=${F2FS_NODE:-$(f2fs_node)} || exit 3
SYSFS=/sys/fs/f2fs/$F2FS_NODE

sysfs_get() { cat "$SYSFS/$1" 2>/dev/null; }
sysfs_set() { echo "$2" > "$SYSFS/$1" 2>/dev/null || log "WARN: cannot set $1=$2"; }

# ---------- copy offload on/off ----------
find_offload_ctl() {
  if [ -n "$COPY_OFFLOAD_CTL" ]; then echo "$COPY_OFFLOAD_CTL"; return; fi
  bn=$(blk_node)
  for p in /sys/block/$bn/queue/copy_offload /sys/block/$bn/slaves/*/queue/copy_offload; do
    if [ -w "$p" ]; then echo "$p"; return; fi
  done
}
set_copy_offload() {   # on|off
  ctl=$(find_offload_ctl)
  if [ -z "$ctl" ]; then
    log "WARN: no copy_offload control found (export COPY_OFFLOAD_CTL=...); run is only labelled '$MODE'"
    return 1
  fi
  if [ "$1" = on ]; then v=${COPY_OFFLOAD_ON_VAL:-1}; else v=${COPY_OFFLOAD_OFF_VAL:-0}; fi
  echo "$v" > "$ctl" && log "copy offload '$1': wrote $v to $ctl"
}

# ---------- tunables ----------
TUNABLES="gc_urgent gc_idle gc_urgent_sleep_time gc_min_sleep_time gc_max_sleep_time gc_no_gc_sleep_time"
save_tunables() {
  : > "$RES_DIR/.tunables"
  for t in $TUNABLES; do
    v=$(sysfs_get "$t"); [ -n "$v" ] && echo "$t $v" >> "$RES_DIR/.tunables"
  done
}
restore_tunables() {
  [ -f "$RES_DIR/.tunables" ] || return
  while read -r t v; do 
    if [ "$t" = "gc_urgent" ] && [ "$v" = "5" ]; then
      v=2
    fi
    sysfs_set "$t" "$v"
  done < "$RES_DIR/.tunables"
}


# ---------- counters ----------
# Parses debugfs "GC calls: N (BG: M)", "Try to move N blocks (BG: M)", "CP calls: N (BG: M)".
f2fs_counters() 
{
  offload_val=$(sysfs_get "copy_offload_calls")
  if [ -z "$offload_val" ]; then offload_val="0"; fi

  if [ ! -r "$DBGFS" ]; then
    echo "gc_calls=NA gc_bg=NA moved=NA moved_bg=NA cp_calls=NA cp_bg=NA co_calls=$offload_val"
    return
  fi

  awk -v co="$offload_val" '
    /GC calls:/    { s=$0; gsub(/[^0-9 ]/," ",s); split(s,a," "); gc=a[1]; gcbg=a[2] }
    /Try to move/  { s=$0; gsub(/[^0-9 ]/," ",s); split(s,a," "); mv=a[1]; mvbg=a[2] }
    /CP calls:/    { s=$0; gsub(/[^0-9 ]/," ",s); split(s,a," "); cp=a[1]; cpbg=a[2] }
	END {
      if (gc == "") gc = "NA"
      if (gcbg == "") gcbg = "NA"
      if (mv == "") mv = "NA"
      if (mvbg == "") mvbg = "NA"
      if (cp == "") cp = "NA"
      if (cpbg == "") cpbg = "NA"

      printf "gc_calls=%s gc_bg=%s moved=%s moved_bg=%s cp_calls=%s cp_bg=%s co_calls=%s\n", \
        gc, gcbg, mv, mvbg, cp, cpbg, co
    }
  ' "$DBGFS"
}


kv() { echo "$1" | tr ' ' '\n' | grep "^$2=" | cut -d= -f2; }
delta() {   # delta "<snap0>" "<snap1>" key
  a=$(kv "$1" "$3"); b=$(kv "$2" "$3")
  case "$a$b" in *NA*) echo NA ;; *) echo $((b - a)) ;; esac }
used_pct() { df -k "$MNT" | awk 'NR==2{gsub("%","",$5); print $5}'; }

# ---------- result recording ----------
emit() { echo "$MODE,$TEST_NAME,$1,$2,$3" >> "$CSV"; log "  $1 = $2 $3"; }
gcval() { echo "$1" | grep "^$2=" | head -n1 | cut -d= -f2; }   # pick key from gcload output
emit_load() {   # emit_load "<gcload output>" prefix key:unit ...
  out=$1; pre=$2; shift 2
  for kvp in "$@"; do
    k=${kvp%%:*}; u=${kvp##*:}
    v=$(gcval "$out" "$k"); [ -n "$v" ] && emit "${pre}${k}" "$v" "$u"
  done
}
#---------- UFS command RAM-log capture ----------

RAMLOG_CMD=${RAMLOG_CMD:-/data/local/tmp/f2fs_gc_suite/ufs_cmd_log}
RAMLOG_PID=""
RAMLOG_FILE=""

ramlog_start() {
  [ -x "$RAMLOG_CMD" ] || {
  log "ERROR: UFS command logger not executable: $RAMLOG_CMD"
  return 1
}

mkdir -p "$RES_DIR/ramlogs"
RAMLOG_FILE="$RES_DIR/ramlogs/${TEST_NAME}"

log "Clearing UFS Ramlog buffer: $TEST_NAME"
"$RAMLOG_CMD" -c || {
    log "ERROR: Failed to clear UFS Ramlog buffer"
    return 1
}

log "Starting UFS Ramlog capture in background"

"$RAMLOG_CMD" -s >/dev/null 2>&1 &
RAMLOG_PID=$!

# Give the application a moment to initialize.
sleep 1

if ! kill -0 "$RAMLOG_PID" 2>/dev/null; then
    wait "$RAMLOG_PID" 2>/dev/null
    RAMLOG_PID=""
    log "ERROR: UFS Ramlog capture process exited unexpectedly"
    return 1
fi

return 0

}

ramlog_stop() {
[ -n "$RAMLOG_PID" ] || return 0

log "Stopping UFS Ramlog capture"

# Request the same graceful termination as Ctrl+C.
kill -INT "$RAMLOG_PID" 2>/dev/null

# Wait for the capture process to finish.
wait "$RAMLOG_PID" 2>/dev/null
RAMLOG_PID=""

log "Saving UFS Ramlog: $RAMLOG_FILE"

if "$RAMLOG_CMD" -l "$RAMLOG_FILE"; then
    log "UFS RAM-log saved: $RAMLOG_FILE"
else
    log "ERROR: Failed to save UFS RAM-log: $RAMLOG_FILE"
    TEST_STATUS=FAIL
    return 1
fi

return 0

}

# ---------- test lifecycle ----------
begin_test() {
  TEST_NAME=$1; TEST_STATUS=PASS
  log "=== $TEST_NAME [$MODE] ==="
  save_tunables
  rm -rf "$TEST_DIR"; mkdir -p "$TEST_DIR"; sync
  T0=$(now_ms); C0=$(f2fs_counters)
}
# Mark the scenario INCONCLUSIVE when the GC type it targets never ran.
need_gt() {
  # need_gt <label> <value> <minimum>

  case "$2" in
    NA)
      if [ "$TEST_STATUS" = PASS ]; then
        TEST_STATUS=UNVERIFIED
      fi
      ;;

    *)
      if [ "$2" -le "$3" ] && [ "$TEST_STATUS" = PASS ]; then
        log "  expected $1 > $3 but got $2"
        TEST_STATUS=INCONCLUSIVE
      fi
      ;;
  esac
}

end_test() {
  ramlog_stop

  T1=$(now_ms); C1=$(f2fs_counters)
  emit duration_ms $((T1 - T0)) ms
  
  for k in gc_calls gc_bg moved moved_bg cp_calls cp_bg co_calls; do
    emit "$k" "$(delta "$C0" "$C1" "$k")" count
  done
  
  # Captures copy-offload metrics for ALL 17 test cases globally
  co_delta=$(delta "$C0" "$C1" co_calls)
  log "  [Copy Offload Metrics] f2fs_gc_try_copy_offload() was called $co_delta times"

  g=$(delta "$C0" "$C1" gc_calls); b=$(delta "$C0" "$C1" gc_bg)
  case "$g$b" in *NA*) emit gc_fg NA count ;; *) emit gc_fg $((g - b)) count ;; esac
  emit status "$TEST_STATUS" -
  restore_tunables
  rm -rf "$TEST_DIR"; sync
  log "=== $TEST_NAME: $TEST_STATUS ==="
}

# ---------- reusable scenarios ---------- # Fill to FILL_PCT with 8MB files, then punch holes by random overwrite/delete so # many segments hold a mix of valid and invalid blocks.
age_fs() {   # age_fs <fill_pct> <delete_pct> <churn_secs>
  "$GCLOAD" fillto "$TEST_DIR" "$1" 8 "$MNT" "${FILL_MAX_MB:-0}" > "$RES_DIR/.fill" 
  cat "$RES_DIR/.fill"
  [ "$3" -gt 0 ] && "$GCLOAD" churn "$TEST_DIR" "$3" 4 0 42 512 > "$RES_DIR/.churn"
  "$GCLOAD" delete "$TEST_DIR" "$2" 99
  sync
}

bg_quiesce() {   # make the BG GC thread effectively idle
  sysfs_set gc_urgent 0
  sysfs_set gc_idle 0
  for t in gc_min_sleep_time gc_max_sleep_time gc_no_gc_sleep_time; do sysfs_set "$t" 600000; done }
free_mb() { df -k "$MNT" | awk 'NR==2{print int($4/1024)}'; }
gc_thread_ticks() {   # utime+stime (clock ticks) of the f2fs_gc kthread
  pid=$(ps -A -o PID,NAME 2>/dev/null | awk '/f2fs_gc/{print $1; exit}')
  if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then awk '{print $14 + $15}' "/proc/$pid/stat"; else echo 0; fi }
  
require_root_f2fs() {
  [ "$(id -u)" = 0 ] || { 
	echo "must run as root (adb root)"
	exit 3
	}
	
  [ -d "$SYSFS" ] || { 
	echo "no f2fs sysfs node for $MNT"
	exit 3
	}

  [ -x "$GCLOAD" ] || { 
	echo "missing $GCLOAD (build tools/gcload.c)"
	exit 3 
	} 
}
