#!/system/bin/sh
# Background GC scenarios. Usage: bg_gc.sh [test_name ...]   (no args = all)
#
# BG GC is driven through the f2fs_gc kthread: default idle-time GC, gc_urgent 
# modes (1=high, 2=low), gc_idle policies (1=cost-benefit, 2=greedy) and the 
# Android idle-maintenance path. Each test ages the fs first so there are # partially-invalid sections to collect.

D=$(cd "$(dirname "$0")" && pwd)
. "$D/../lib/common.sh"

BG_TESTS="bg_default_idle bg_urgent_high bg_urgent_low bg_idle_cost_benefit bg_idle_greedy bg_with_foreground_io bg_reclaim_after_delete bg_fsync_workload bg_waf_soak bg_idle_maint"
BG_SLEEP_MS=${BG_SLEEP_MS:-500}

short_sleeps() { for t in gc_min_sleep_time gc_max_sleep_time gc_no_gc_sleep_time; do sysfs_set "$t" "$BG_SLEEP_MS"; done; }

bg_age() { age_fs "$FILL_PCT" 15 "$(scale_min1 60)"; sleep 2; }

need_bg() {      # scenario is only valid if the background GC thread actually collected
  c=$(f2fs_counters)
  need_gt bg_gc_calls "$(delta "$C0" "$c" gc_bg)" 0 
}

# Sample the fs for <secs> seconds with no foreground IO and emit BG GC metrics.
bg_measure() {   # bg_measure <prefix> <secs>
  f0=$(sysfs_get free_segments); d0=$(sysfs_get dirty_segments)
  c0=$(f2fs_counters); k0=$(gc_thread_ticks); t0=$(now_ms)
  sleep "$2"
  f1=$(sysfs_get free_segments); d1=$(sysfs_get dirty_segments)
  c1=$(f2fs_counters); k1=$(gc_thread_ticks); t1=$(now_ms)
  el=$((t1 - t0)); mv=$(delta "$c0" "$c1" moved_bg)
  emit "${1}elapsed_ms" "$el" ms
  emit "${1}free_seg_gain" $(( ${f1:-0} - ${f0:-0} )) segs
  emit "${1}dirty_seg_delta" $(( ${d1:-0} - ${d0:-0} )) segs
  emit "${1}bg_gc_calls" "$(delta "$c0" "$c1" gc_bg)" count
  emit "${1}bg_blocks_moved" "$mv" blocks
  case "$mv" in NA) ;; *)
    emit "${1}bg_moved_mb_s" "$(awk -v m="$mv" -v e="$el" 'BEGIN{printf "%.2f", m*4/1024/(e/1000)}')" MB/s ;;
  esac
  emit "${1}gc_thread_cpu_ms" $(( (k1 - k0) * 10 )) ms     # assumes CLK_TCK=100
}

# One foreground-IO phase: random 4K overwrites; emits iops and latencies.
io_phase() {     # io_phase <prefix> <secs> <io_kb> <fsync_every>
  out=$("$GCLOAD" churn "$TEST_DIR" "$2" "$3" "$4" 11 512)
  emit_load "$out" "$1" iops:ops/s mb_s:MB/s write_p50_us:us write_p99_us:us write_p999_us:us write_max_us:us fsync_p99_us:us fsync_max_us:us
  IO_IOPS=$(gcval "$out" iops); IO_OPS=$(gcval "$out" ops) }
pct_drop() { awk -v a="$1" -v b="$2" 'BEGIN{ if (a>0) printf "%.1f", (a-b)*100/a; else print "NA" }'; }

# 1. Stock tunables, no IO: does idle-time BG GC kick in and reclaim?
t_bg_default_idle() {
  begin_test bg_default_idle; bg_age
  bg_measure idle_ "$(scale_min1 300)"
  need_bg; end_test
}

# 2/3. gc_urgent modes: GC runs flat out regardless of idleness.
t_bg_urgent_high() {
  begin_test bg_urgent_high; bg_age
  sysfs_set gc_urgent 1
  bg_measure urgent_high_ "$(scale_min1 120)"
  need_bg; end_test
}

t_bg_urgent_low() {
  begin_test bg_urgent_low; bg_age
  sysfs_set gc_urgent 2
  bg_measure urgent_low_ "$(scale_min1 120)"
  need_bg; end_test
}

# 4/5. gc_idle victim-selection policies with short thread sleeps.
t_bg_idle_cost_benefit() {
  begin_test bg_idle_cost_benefit; bg_age
  short_sleeps; sysfs_set gc_idle 1
  bg_measure costben_ "$(scale_min1 120)"
  need_bg; end_test
}

t_bg_idle_greedy() {
  begin_test bg_idle_greedy; bg_age
  short_sleeps; sysfs_set gc_idle 2
  bg_measure greedy_ "$(scale_min1 120)"
  need_bg; end_test
}

# 6. Foreground random writes with BG GC off vs on: cost of BG GC to user IO.
t_bg_with_foreground_io() {
  begin_test bg_with_foreground_io; bg_age
  bg_quiesce
  io_phase base_ "$(scale_min1 60)" 4 0; base=$IO_IOPS
  sysfs_set gc_urgent 2; short_sleeps
  io_phase bgon_ "$(scale_min1 60)" 4 0; on=$IO_IOPS
  emit iops_drop_pct "$(pct_drop "$base" "$on")" %
  need_bg; end_test
}

# 7. Delete a large share of data, then watch free segments recover with BG GC.
t_bg_reclaim_after_delete() {
  begin_test bg_reclaim_after_delete
  "$GCLOAD" fillto "$TEST_DIR" "$FILL_PCT" 8 "$MNT" "${FILL_MAX_MB:-0}" > /dev/null
  "$GCLOAD" churn "$TEST_DIR" "$(scale_min1 30)" 4 0 21 512 > /dev/null
  "$GCLOAD" delete "$TEST_DIR" 40 77 > /dev/null; sync
  short_sleeps; sysfs_set gc_idle 1
  f0=$(sysfs_get free_segments); c0=$(f2fs_counters); t0=$(now_ms)
  prev=-1; same=0; limit=$(scale_min1 300); s=0
  while [ "$s" -lt "$limit" ] && [ "$same" -lt 3 ]; do
    sleep 5; s=$((s + 5)); f=$(sysfs_get free_segments)
    if [ "$f" = "$prev" ]; then 
        same=$((same + 1)); 
    else 
        same=0; 
    fi; 
    prev=$f
  done
  emit time_to_stable_s $(( $(now_ms) - t0 )) ms
  emit free_seg_gain $(( ${prev:-0} - ${f0:-0} )) segs
  emit bg_blocks_moved "$(delta "$c0" "$(f2fs_counters)" moved_bg)" blocks
  need_bg; end_test
}

# 8. fsync-heavy small writes with BG GC off vs urgent-low (checkpoint interplay).
t_bg_fsync_workload() {
  begin_test bg_fsync_workload; bg_age
  bg_quiesce
  io_phase base_ "$(scale_min1 60)" 4 1; base=$IO_IOPS
  sysfs_set gc_urgent 2; short_sleeps
  io_phase bgon_ "$(scale_min1 60)" 4 1; on=$IO_IOPS
  emit iops_drop_pct "$(pct_drop "$base" "$on")" %
  need_bg; end_test
}

# 9. Soak: random overwrites while BG GC runs; derive GC write amplification.
t_bg_waf_soak() {
  begin_test bg_waf_soak
  age_fs "$FILL_PCT" 10 0
  short_sleeps; sysfs_set gc_idle 1
  c0=$(f2fs_counters)
  io_phase soak_ "$(scale_min1 300)" 4 0
  c1=$(f2fs_counters)
  moved=$(delta "$c0" "$c1" moved); mbg=$(delta "$c0" "$c1" moved_bg)
  emit gc_blocks_moved_total "$moved" blocks
  emit gc_blocks_moved_bg "$mbg" blocks
  case "$moved" in NA) ;; *)
    emit gc_waf "$(awk -v u="$IO_OPS" -v m="$moved" 'BEGIN{ if (u>0) printf "%.3f", (u+m)/u; else print "NA" }')" ratio ;;
  esac
  need_bg; end_test
}

# 10. Android idle maintenance (vold/StorageManager drives GC via gc_urgent).
t_bg_idle_maint() {
  begin_test bg_idle_maint
  if ! command -v sm > /dev/null 2>&1; then
    log "'sm' not available; skipping"; TEST_STATUS=SKIPPED; end_test; return
  fi
  bg_age
  sm idle-maint run > /dev/null 2>&1
  bg_measure maint_ "$(scale_min1 300)"
  sm idle-maint abort > /dev/null 2>&1
  need_bg; end_test
}

require_root_f2fs
set_copy_offload "$([ "$MODE" = offload_on ] && echo on || echo off)"
[ $# -eq 0 ] && set -- $BG_TESTS
for t in "$@"; do
  if type "t_$t" > /dev/null 2>&1; then "t_$t"; else echo "unknown test: $t"; fi done
