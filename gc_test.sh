#!/system/bin/sh

MOUNT_POINT="/data"
TEST_DIR="/data/f2fs_gc_test"

FILE_SIZE_KB=256
FILE_COUNT=4096
DELETE_PERCENT=50

echo "=============================================="
echo "       F2FS CONTROLLED GARBAGE COLLECTION"
echo "=============================================="

echo "[INFO] Mount point : $MOUNT_POINT"
echo "[INFO] Test dir    : $TEST_DIR"
echo "[INFO] File size   : ${FILE_SIZE_KB} KB"
echo "[INFO] File count  : $FILE_COUNT"
echo "[INFO] Total data  : 1 GiB"

echo
echo "[INFO] Filesystem:"
mount | grep " $MOUNT_POINT "

echo
echo "[INFO] F2FS sysfs:"
ls -d /sys/fs/f2fs/* 2>/dev/null

rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

echo
echo "[PHASE 1] Creating files..."

i=0

while [ $i -lt $FILE_COUNT ]; do

    dd if=/dev/zero \
       of="$TEST_DIR/file_$i" \
       bs=256K \
       count=1 \
       2>/dev/null

    i=$((i + 1))

    if [ $((i % 128)) -eq 0 ]; then
        echo "[CREATE] $i / $FILE_COUNT files created"
        echo "[CREATE] Current usage:"
        du -sh "$TEST_DIR"
    fi
done

sync

echo
echo "[PHASE 1 COMPLETE]"
echo "[INFO] Created files:"
ls -1 "$TEST_DIR" | wc -l

echo "[INFO] Directory usage:"
du -sh "$TEST_DIR"

echo
echo "[PHASE 2] Deleting 50% of files..."

i=0
DELETE_COUNT=$((FILE_COUNT / 2))

while [ $i -lt $DELETE_COUNT ]; do

    rm -f "$TEST_DIR/file_$i"

    i=$((i + 1))

    if [ $((i % 128)) -eq 0 ]; then
        echo "[DELETE] $i / $DELETE_COUNT files deleted"
    fi
done

sync

echo
echo "[PHASE 2 COMPLETE]"

echo "[INFO] Remaining files:"
ls -1 "$TEST_DIR" | wc -l

echo "[INFO] Directory usage:"
du -sh "$TEST_DIR"

echo
echo "[PHASE 3] Filesystem status..."

df -h "$MOUNT_POINT"

echo
echo "[PHASE 4] Finding F2FS sysfs..."

F2FS_DIR=""

for d in /sys/fs/f2fs/*; do
    if [ -d "$d" ]; then
        F2FS_DIR="$d"
        echo "[INFO] F2FS directory: $d"
    fi
done

if [ -z "$F2FS_DIR" ]; then
    echo "[ERROR] F2FS sysfs directory not found"
    exit 1
fi

echo
echo "[PHASE 5] GC urgent trigger"

echo "[INFO] gc_urgent before:"
cat "$F2FS_DIR/gc_urgent" 2>/dev/null

echo 1 > "$F2FS_DIR/gc_urgent"

echo "[INFO] gc_urgent after:"
cat "$F2FS_DIR/gc_urgent" 2>/dev/null

echo
echo "[PHASE 5 COMPLETE]"
echo "[INFO] Monitor dmesg for F2FS GC activity."

echo
echo "=============================================="
echo "TEST COMPLETE"
echo "=============================================="
