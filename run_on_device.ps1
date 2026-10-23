# ==============================================================================
# F2FS GC Test Suite Windows PowerShell Wrapper (Pre-built gcload)
# ==============================================================================
# INSTRUCTIONS: Update the configurations below, then run in PowerShell:
#               .\run_on_device.ps1
# ==============================================================================

# --- USER CONFIGURATION ---
$MNT          = "/mnt/test"   # Your target partition
$FILL_PCT     = "85"          
$SCALE_PCT    = "10"          
$MODES        = "offload_off offload_on"
$SUITES       = "fg bg"       

# --- SYSTEM VARIABLES ---
$DEV_DIR  = "/data/local/tmp/f2fs_gc_suite"

if (-not (Test-Path ".\gcload")) {
    Write-Error "Error: gcload binary not found in the current directory!"
    Exit
}

# ==============================================================================
# STEP 1: Prepare the Android Device via ADB
# ==============================================================================
Write-Host ">>> Initializing ADB connection..." -ForegroundColor Cyan
& adb root
Start-Sleep -Seconds 1
& adb wait-for-device

Write-Host ">>> Preparing directories on device..." -ForegroundColor Cyan
& adb shell "rm -rf $DEV_DIR/lib $DEV_DIR/tests $DEV_DIR/results; mkdir -p $DEV_DIR"

Write-Host ">>> Pushing files and test suite to device..." -ForegroundColor Cyan
& adb push .\lib "$DEV_DIR/"
& adb push .\tests "$DEV_DIR/"
& adb push .\run_all.sh "$DEV_DIR/"
& adb push .\gcload "$DEV_DIR/"

Write-Host ">>> Adjusting file permissions on device..." -ForegroundColor Cyan
& adb shell "chmod 755 $DEV_DIR/gcload $DEV_DIR/run_all.sh $DEV_DIR/tests/*.sh"

# ==============================================================================
# STEP 2: Execute the Suite on Target Device
# ==============================================================================
Write-Host ">>> Launching test suite on target device..." -ForegroundColor Magenta

# Find the real active f2fs storage node on the device (excluding the 'features' folder)
$realNode = & adb shell "ls /sys/fs/f2fs | grep -v features | head -n1"
$realNode = $realNode.Trim()

if (-not $realNode) {
    Write-Warning "Could not dynamically find a discrete F2FS sysfs node name. Falling back to defaults."
    $nodeExport = ""
} else {
    Write-Host ">>> Routing benchmark adjustments to active sysfs target node: $realNode" -ForegroundColor Yellow
    # We alter the internal function behavior by manually populating the expected $node parameter context
    $nodeExport = "export node='$realNode' && "
}

# Construct pipeline command wrapper string
$deviceCmd = "cd $DEV_DIR && " +
             "export MNT='$MNT' && " +
             "export FILL_PCT='$FILL_PCT' && " +
             "export SCALE_PCT='$SCALE_PCT' && " +
             "export MODES='$MODES' && " +
             "export SUITES='$SUITES' && " +
             $nodeExport +
             "export GCLOAD='$DEV_DIR/gcload' && " +
             "/system/bin/sh run_all.sh"

& adb shell $deviceCmd

# ==============================================================================
# STEP 3: Pull Results and Run Python Evaluation
# ==============================================================================
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$outDir = ".\results\$timestamp"

Write-Host ">>> Pulling test logs from device..." -ForegroundColor Cyan
$dirExists = & adb shell "[ -d $DEV_DIR/results ] && echo 'yes' || echo 'no'"
if ($dirExists -match "yes") {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    & adb pull "$DEV_DIR/results/." "$outDir/"
    Write-Host "Results saved successfully to $outDir" -ForegroundColor Green
    
    if (Get-Command py -ErrorAction SilentlyContinue) {
        Write-Host ">>> Executing data comparison script via py launcher..." -ForegroundColor Cyan
        & py ".\tools\compare.py" "$outDir"
    } elseif (Get-Command python -ErrorAction SilentlyContinue) {
        Write-Host ">>> Executing data comparison script..." -ForegroundColor Cyan
        & python ".\tools\compare.py" "$outDir"
    } else {
        Write-Host "Warning: Python environment execution failed. Please run manually: python .\tools\compare.py $outDir" -ForegroundColor Yellow
    }
} else {
    Write-Error "The test script exited prematurely on the device and did not generate any results folder."
}
