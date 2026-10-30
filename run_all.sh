#!/system/bin/sh
# On-device driver: runs the FG and BG GC suites with copy offload off, then on.
#
#   MODES="offload_off offload_on"   which passes to run (default both)
#   SUITES="fg bg"                   which suites to run (default both)
#   TESTS="fg_append_full ..."       optional subset of test names (suite inferred)
#
# Results land in $SUITE_DIR/results/<mode>/results.csv

SUITE_DIR=${SUITE_DIR:-/data/local/tmp/f2fs_gc_suite}
MODES=${MODES:-"offload_off offload_on"} 
SUITES=${SUITES:-"fg bg"} 

cd "$SUITE_DIR" || exit 1

capture_env() {   # capture_env <mode>
  d=$SUITE_DIR/results/$1; mkdir -p "$d"
  {
    echo "date: $(date)"
    echo "kernel: $(uname -a)"
    echo "model: $(getprop ro.product.model 2>/dev/null)"
    echo "fingerprint: $(getprop ro.build.fingerprint 2>/dev/null)"
    echo "f2fs mounts:"; grep f2fs /proc/mounts
    echo "suite env: MNT=${MNT:-/data} FILL_PCT=${FILL_PCT:-80} SCALE_PCT=${SCALE_PCT:-100} FILL_MAX_MB=${FILL_MAX_MB:-0}"
    echo "copy_offload ctl: ${COPY_OFFLOAD_CTL:-autodetect}"
  } > "$d/env.txt"
  
  # Resolve node dynamically based on what is actually mounted to $MNT
  dev_path=$(awk -v m="$MNT" '$2==m && $3=="f2fs" {print $1}' /proc/mounts)
  node=${F2FS_NODE:-${dev_path##*/}}

  
  [ -n "$node" ] && { echo "--- sysfs tunables ($node)"; for f in /sys/fs/f2fs/$node/gc_* /sys/fs/f2fs/$node/main_blkaddr; do echo "$(basename $f)=$(cat $f 2>/dev/null)"; done; } >> "$d/env.txt"
}


for m in $MODES; do
  export MODE=$m
  capture_env "$m"
  echo "################ MODE=$m ################"
  for s in $SUITES; do
    case "$s" in
      fg) sh tests/fg_gc.sh $TESTS ;;
      bg) sh tests/bg_gc.sh $TESTS ;;
    esac
  done
done
echo "done. results in $SUITE_DIR/results/"
