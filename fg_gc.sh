#!/system/bin/sh
# Foreground GC scenarios. Usage: fg_gc.sh [test_name ...]   (no args = all)
#
# Foreground GC is forced by 
# (a) quiescing the background GC thread and 
# (b) running writers on an aged, nearly full filesystem, so the write path 
#     itself has to reclaim sections (or by calling the GC ioctl with sync=1).

D=$(cd "$(dirname "$0")" && pwd)
. "$D/../lib/common.sh"

FG_TESTS="fg_append_full fg_random_overwrite fg_fsync_pressure fg_parallel_writers fg_ioctl_sync_gc fg_ioctl_gc_range fg_enospc_recovery"

bg_quiesce() {   # make the BG GC thread effectively idle for the whole test
  sysfs_set gc_urgent 0
  sysfs_set gc_idle 0
  for t in gc_min_sleep_time gc_max_sleep_time gc_no_gc_sleep_time; do sysfs_set "$t" 600000; done 
}

free_mb() { df -k "$MNT" | awk 'NR==2{print int($4/1024)}'; }

prep_full() {    # prep_full <fill_pct> <churn_secs> <delete_pct>
  bg_quiesce
  age_fs "$1" "$3" "$2"
}

need_fg() {      # scenario is only valid if foreground GC actually ran
  c=$(f2fs_counters)
  g=$(delta "$C0" "$c" gc_calls)
  b=$(delta "$C0" "$c" gc_bg)
  
  case "$g$b" in 
	*NA*) 
		need_gt fg_gc_calls NA 0 
		;; 
	*)
		need_gt fg_gc_calls $((g - b)) 0 
		;; 
	esac 
} 

APPEND_METRICS="mb_s:MB/s elapsed_ms:ms enospc:flag write_p50_us:us write_p99_us:us write_p999_us:us write_max_us:us"

# 1. Sequential append into the last free space of an aged fs: write stalls from FG GC.
t_fg_append_full() {
  begin_test fg_append_full
  prep_full 95 "$(scale_min1 120)" 5

  free=$(free_mb)
  tot=$(( free * 120 / 100 ))

  [ "$tot" -gt 0 ] || {
    log "ERROR: no free space available for append workload"
    TEST_STATUS=FAIL
    end_test
    return
  }
  ramlog_start ||:
  out=$("$GCLOAD" append "$TEST_DIR" "$tot" 128 0 64)
  emit_load "$out" append_ $APPEND_METRICS
  ramlog_stop
  need_fg; end_test
}

# 2. Random 4K overwrites on a ~90% full fs: out-of-place updates need free sections.
t_fg_random_overwrite() {
  begin_test fg_random_overwrite
  prep_full 95 "$(scale_min1 120)" 0
  ramlog_start ||:
  out=$("$GCLOAD" churn "$TEST_DIR" "$(scale_min1 300)" 4 0 7 512)
  emit_load "$out" churn_ iops:ops/s mb_s:MB/s enospc:flag write_p50_us:us write_p99_us:us write_p999_us:us write_max_us:us
  ramlog_stop
  need_fg; end_test
}

# 3. Small appends with fsync after every chunk (checkpoint/fsync + FG GC interplay).
t_fg_fsync_pressure() {
  begin_test fg_fsync_pressure
  prep_full 95 "$(scale_min1 120)" 5

  free=$(free_mb)
  tot=$(( free * 110 / 100 ))

  [ "$tot" -gt 0 ] || {
    log "ERROR: insufficient free space for fsync-pressure test"
    TEST_STATUS=FAIL
    end_test
    return
  }
  ramlog_start ||:
  out=$("$GCLOAD" append "$TEST_DIR" "$tot" 16 1 32)
  emit_load "$out" fsyncappend_ $APPEND_METRICS
  ramlog_stop
  need_fg; end_test
}

# 4. Four concurrent appenders contending for the same free sections.
t_fg_parallel_writers() {
  begin_test fg_parallel_writers
  prep_full 90 "$(scale_min1 60)" 10

  each=$(( $(free_mb) * 20 / 100 ))
  writer_pids=""
  writer_rc=0

  # Start RAM-log capture before launching the writers.
  ramlog_start || :

  for i in 0 1 2 3; do
    mkdir -p "$TEST_DIR/w$i"
    (
      "$GCLOAD" append "$TEST_DIR/w$i" "$each" 128 0 64 \
        > "$RES_DIR/.w$i"
    ) &
    writer_pids="$writer_pids $!"
  done

  # Wait only for the writer processes, not all background jobs.
  for pid in $writer_pids; do
    wait "$pid" || writer_rc=1
  done

  # Stop and save the RAM log after all writers have finished.
  ramlog_stop || writer_rc=1

  agg=$(cat "$RES_DIR"/.w[0-3] |
    awk -F= '/^mb_s=/{s+=$2} END{printf "%.1f", s}')
  p99=$(cat "$RES_DIR"/.w[0-3] |
    awk -F= '/^write_p99_us=/{if($2>m)m=$2} END{print m+0}')
  mx=$(cat "$RES_DIR"/.w[0-3] |
    awk -F= '/^write_max_us=/{if($2>m)m=$2} END{print m+0}')
  ens=$(cat "$RES_DIR"/.w[0-3] |
    awk -F= '/^enospc=/{s+=$2} END{print s+0}')

  emit par_aggregate_mb_s "$agg" MB/s
  emit par_worst_write_p99_us "$p99" us
  emit par_worst_write_max_us "$mx" us
  emit par_enospc_writers "$ens" count

  need_fg
  end_test
}

# 5. Explicit synchronous GC via F2FS_IOC_GARBAGE_COLLECT (sync=1) until no victim is left.
t_fg_ioctl_sync_gc() {
  begin_test fg_ioctl_sync_gc
  prep_full 85 "$(scale_min1 60)" 20
  ramlog_start ||:
  out=$("$GCLOAD" gc "$TEST_DIR" 1 "$(scale_min1 2000)")
  emit_load "$out" ioctl_ calls:count ok:count busy:count last_errno:errno elapsed_ms:ms gc_call_p50_us:us gc_call_p99_us:us gc_call_max_us:us
  ramlog_stop
  need_fg; end_test
}

# 6. Range GC (F2FS_IOC_GARBAGE_COLLECT_RANGE) over the start of the main area.
t_fg_ioctl_gc_range() {
  begin_test fg_ioctl_gc_range
  mb=$(sysfs_get main_blkaddr)
  if [ -z "$mb" ]; then
    log "main_blkaddr not exposed by this kernel; skipping"; TEST_STATUS=SKIPPED; end_test; return
  fi
  prep_full 85 "$(scale_min1 60)" 20
  len=$(( 512 * 2048 ))   # 2048 segments (~4GB with 2MB segments)
  ramlog_start ||:
  out=$("$GCLOAD" gcrange "$TEST_DIR" "$mb" "$len" 1)
  emit_load "$out" range_ ret:rc errno:errno elapsed_ms:ms
  ramlog_stop
  [ "$(gcval "$out" ret)" = 0 ] || TEST_STATUS=FAIL
  need_fg; end_test
}

# 7. Fill to ENOSPC, free 20% of files, and check writes recover (FG GC reclaims space).
t_fg_enospc_recovery() {
  begin_test fg_enospc_recovery
  bg_quiesce
  out=$("$GCLOAD" fillto "$TEST_DIR" 100 8 "$MNT")
  fill_rc=$?

  emit_load "$out" fill_ files:count used_pct:% enospc:flag mb_s:MB/s

  if [ "$fill_rc" -ne 0 ]; then
    log "ERROR: fillto failed with exit code $fill_rc"
    TEST_STATUS=FAIL
    end_test
    return
  fi

  fill_enospc=$(gcval "$out" enospc)

  if [ "$fill_enospc" != 1 ]; then
    log "ERROR: fill phase did not confirm ENOSPC"
    TEST_STATUS=FAIL
    end_test
    return
  fi
  "$GCLOAD" churn "$TEST_DIR" "$(scale_min1 30)" 4 0 3 512 > /dev/null 2>&1
  "$GCLOAD" delete "$TEST_DIR" 20 5 > /dev/null; sync
  ramlog_start ||:
  out=$("$GCLOAD" append "$TEST_DIR" "$(( $(free_mb) * 60 / 100 ))" 128 0 64)
  emit_load "$out" recover_ $APPEND_METRICS
  ramlog_stop
  [ "$(gcval "$out" enospc)" = 0 ] || TEST_STATUS=FAIL
  need_fg; end_test
}

require_root_f2fs
#set_copy_offload "$([ "$MODE" = offload_on ] && echo on || echo off)"
[ $# -eq 0 ] && set -- $FG_TESTS
for t in "$@"; do
  if type "t_$t" > /dev/null 2>&1; then 
    "t_$t"; 
  else 
    echo "unknown test: $t"; 
  fi 
done
