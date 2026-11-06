<#
.SYNOPSIS
  Pushes and runs the F2FS GC copy-offload A/B benchmark (gcbench) via adb, then
  pulls the CSV and builds the summary table.

.DESCRIPTION
  Expects, in the same folder as this script: gcbench (compiled aarch64 binary),
  gcbench.sh and gcbench_report.py.
  WARNING: gcbench.sh reformats -Dev on every run. Use the test partition only.

.EXAMPLE
  .\run_gcbench.ps1 -Phase Smoke
  .\run_gcbench.ps1 -Phase Main
  .\run_gcbench.ps1 -Phase Sweep
  .\run_gcbench.ps1 -Phase FgImpact
  .\run_gcbench.ps1 -Phase All
#>
[CmdletBinding()]
param(
    [ValidateSet('Preflight','Smoke','Main','Sweep','FgImpact','All')]
    [string]$Phase = 'Smoke',

    [string]$Serial     = '',                       # adb -s <serial>, if several devices
    [string]$Dev        = '/dev/block/sdg',
    [string]$Blk        = 'sdg',
    [string]$Mnt        = '/mnt/test',            # same mount the existing suite uses
    [string]$Mkfs       = 'make_f2fs -f',           # match common.sh
    [string]$MountOpts  = '',                       # empty = reuse current mount options with background_gc=off
    [switch]$NoMkfs,                                # do NOT mkfs/mount; reuse the existing mount (less controlled)
    [string]$Qnode      = '',                       # default /sys/block/<Blk>/queue/copy_offload
    [string]$Cnode      = '',                       # default /sys/fs/f2fs/<Blk>/copy_offload_calls
    [string]$Moved      = '',                       # default /sys/fs/f2fs/<Blk>/moved_blocks_foreground
    [int]$Nseg          = 4096,                     # 2 MiB victim segments (4096 = 8 GiB written)
    [int]$Reps          = 5,
    [string]$Gov        = 'performance',
    [switch]$SetPermissive,                         # run 'setenforce 0' (userdebug only)
    [string]$OutDir     = (Join-Path $PSScriptRoot 'results'),
    [int]$PollSeconds   = 30,
    [int]$StallMinutes  = 45                        # fail if the log does not change for this long
)

$ErrorActionPreference = 'Continue'   # native stderr must not abort; errors are checked explicitly
$RemoteDir = '/data/local/tmp'
$Script:AdbArgs = @()
if ($Serial) { $Script:AdbArgs = @('-s', $Serial) }

function Adb {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]]$Rest)
    $a = $Script:AdbArgs
    # Explicitly call the native executable directly
    & "adb.exe" @a @Rest 
}

function AdbShell([string]$Cmd) {
    # Call your corrected wrapper function 'Adb' to maintain tracking and parameters safely
    $out = Adb shell $Cmd 2>&1
    return ($out | ForEach-Object { "$_" }) -join "`n"
}

function Step([string]$Msg) { Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }
function Fail([string]$Msg) { Write-Host "ERROR: $Msg" -ForegroundColor Red; exit 1 }

if (-not $Qnode) { $Qnode = "/sys/block/$Blk/queue/copy_offload" }
if (-not $Cnode) { $Cnode = "/sys/fs/f2fs/$Blk/copy_offload_calls" }
if (-not $Moved) { $Moved = "/sys/fs/f2fs/$Blk/moved_blocks_foreground" }

# ---------- local files ----------
Step 'Checking local files'
foreach ($f in 'gcbench', 'gcbench.sh', 'gcbench_report.py') {
    if (-not (Test-Path (Join-Path $PSScriptRoot $f))) { Fail "Missing $f next to this script ($PSScriptRoot)" }
}
if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { Fail 'adb not found in PATH' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---------- device ----------
Step 'Connecting to device'
Adb root | Out-Null
Start-Sleep -Seconds 2
Adb wait-for-device
$who = (AdbShell 'id -u').Trim()
if ($who -ne '0') { Fail "adb shell is not root (uid=$who). Use a userdebug build." }
if ($SetPermissive) { AdbShell 'setenforce 0' | Out-Null; Write-Host 'SELinux set to permissive' }

Step 'Pushing files'
# Normalize line endings safely to avoid corrupting shell functions or adding BOM markers
$sh = Join-Path $PSScriptRoot 'gcbench.sh'
$tmpSh = Join-Path $env:TEMP 'gcbench.sh'

# Read as raw bytes/text and strip out carriage returns explicitly
$content = [System.IO.File]::ReadAllText($sh) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($tmpSh, $content, [System.Text.Encoding]::UTF8)

Adb push (Join-Path $PSScriptRoot 'gcbench') "$RemoteDir/gcbench" | Out-Null
Adb push $tmpSh "$RemoteDir/gcbench.sh" | Out-Null
AdbShell "chmod 755 $RemoteDir/gcbench $RemoteDir/gcbench.sh" | Out-Null


# ---------- preflight ----------
Step 'Preflight checks'
$ok = $true
$mounted = AdbShell "grep f2fs /proc/mounts"
#Write-Host "f2fs mounts on device:`n$mounted"
if ($mounted -notmatch [regex]::Escape($Mnt)) {
    Write-Host "NOTE: $Mnt is not an f2fs mount right now. That is fine only if gcbench should mkfs+mount $Dev itself." -ForegroundColor Yellow
    if ($NoMkfs) { Fail "-NoMkfs needs $Mnt mounted as f2fs." }
}
if ($NoMkfs) { Write-Host 'Mode: -NoMkfs (existing mount reused, nothing is reformatted).' -ForegroundColor Yellow }
else         { Write-Host "Mode: REFORMAT $Dev before every run. Press Ctrl+C within 5 s to abort." -ForegroundColor Yellow; Start-Sleep -Seconds 5 }
$checks = @(
    @{ Name = 'copy_offload toggle'; Cmd = "ls $Qnode";                         Required = $true  },
    @{ Name = 'copy_max_hw_bytes';   Cmd = "cat /sys/block/$Blk/queue/copy_max_hw_bytes"; Required = $false },
    @{ Name = 'mkfs tool';           Cmd = "which $($Mkfs.Split(' ')[0])";        Required = $true  },
    @{ Name = 'device node';         Cmd = "ls $Dev";                              Required = $true  },
    @{ Name = 'printk/drop_caches';  Cmd = 'ls /proc/sys/vm/drop_caches';          Required = $true  }
)
foreach ($c in $checks) {
    $r = AdbShell $c.Cmd
    if ($r -match 'No such file|not found|inaccessible' -or -not $r.Trim()) {
        if ($c.Required) { Write-Host ("[FAIL] {0}: {1}" -f $c.Name, $r.Trim()) -ForegroundColor Red; $ok = $false }
        else             { Write-Host ("[warn] {0}: {1}" -f $c.Name, $r.Trim()) -ForegroundColor Yellow }
    } else { Write-Host ("[ ok ] {0}: {1}" -f $c.Name, $r.Trim()) -ForegroundColor Green }
}
Write-Host ("copy_offload now: " + (AdbShell "cat $Qnode").Trim())
Write-Host "f2fs counters (only exist while $Dev is mounted as f2fs):  $Cnode , $Moved"
Write-Host 'If those two are missing after mount, gcbench falls back to 0 for them; override with -Cnode / -Moved.'
if (-not $ok) { Fail 'Preflight failed - fix the items above.' }
if ($Phase -eq 'Preflight') { Write-Host "`nPreflight done." -ForegroundColor Green; exit 0 }

# ---------- run helper ----------
function Invoke-Bench {
    param([string]$Label, [hashtable]$Knobs)

    Step "Running: $Label"
    $vars = [ordered]@{
        DEV = $Dev; BLK = $Blk; MNT = $Mnt; MKFS = $Mkfs; GOV = $Gov
        QNODE = $Qnode; CNODE = $Cnode; MOVED = $Moved; NO_MKFS = $(if ($NoMkfs) { 1 } else { 0 })
    }
    if ($MountOpts) { $vars['MOUNT_OPTS'] = $MountOpts }
    foreach ($k in $Knobs.Keys) { $vars[$k] = $Knobs[$k] }
    $assign = ($vars.GetEnumerator() | ForEach-Object { "{0}='{1}'" -f $_.Key, $_.Value }) -join ' '

    $log = "$RemoteDir/gcbench_$Label.log"
    AdbShell "rm -f $log" | Out-Null
    AdbShell "$assign nohup sh $RemoteDir/gcbench.sh > $log 2>&1 &" | Out-Null
    Write-Host "Started in background on device; log: $log"

    $csvRemote = $null
    $prevTail = ''
    $lastChange = Get-Date
    while ($true) {
        Start-Sleep -Seconds $PollSeconds
        try { $tail = AdbShell "tail -n 4 $log" } catch { Write-Host 'adb hiccup, retrying...' -ForegroundColor Yellow; continue }
        $last = ($tail -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        if ($last) { Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $last.Substring(0, [Math]::Min(150, $last.Length))) }
        if ($tail -match 'ABORT:') {
            Write-Host "`n--- device log tail ($log) ---" -ForegroundColor Red
            Write-Host (AdbShell "tail -n 25 $log") -ForegroundColor Red
            Fail "Run '$Label' aborted on the device (see ABORT line above)."
        }
        if ($tail -match 'done: (\S+\.csv)') { $csvRemote = $Matches[1]; break }
        if ($tail -ne $prevTail) { $prevTail = $tail; $lastChange = Get-Date }
        elseif (((Get-Date) - $lastChange).TotalMinutes -gt $StallMinutes) {
            Fail "No log progress for $StallMinutes min - run looks hung. Check: adb shell cat $log ; adb shell dmesg | tail -50"
        }
    }

    $localCsv = Join-Path $OutDir ("{0}_{1}" -f $Label, (Split-Path $csvRemote -Leaf))
    Adb pull $csvRemote $localCsv | Out-Null
    Adb pull $log (Join-Path $OutDir "$Label.log") | Out-Null
    Write-Host "Pulled: $localCsv" -ForegroundColor Green

    # a header-only CSV means nothing ran: never report that as success
    $rows = @(Import-Csv $localCsv)
    if ($rows.Count -eq 0) {
        Write-Host (AdbShell "tail -n 40 $log") -ForegroundColor Red
        Fail "CSV has no result rows - no test actually ran. See the device log above."
    }
    Write-Host "Result rows: $($rows.Count)"

    # integrity gate
    $bad = Import-Csv $localCsv | Where-Object { $_.verify -ne 'OK' -or [int]$_.bad -ne 0 }
    if ($bad) {
        Write-Host 'DATA INTEGRITY FAILURE in these runs:' -ForegroundColor Red
        $bad | Format-Table mode, keep, pattern, rep, verify, bad
        Write-Host 'Stop and send me this CSV plus dmesg (adb shell dmesg > dmesg.txt).' -ForegroundColor Red
    }

    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
    if ($py) {
        $md = [IO.Path]::ChangeExtension($localCsv, '.md')
        & $py.Source (Join-Path $PSScriptRoot 'gcbench_report.py') $localCsv | Out-File -Encoding utf8 $md
        Write-Host "`n--- Summary ($md) ---" -ForegroundColor Cyan
        Get-Content $md
    } else {
        Write-Host 'Python not found; run gcbench_report.py manually on the CSV.' -ForegroundColor Yellow
    }
    $ioNow = [int]((AdbShell "dmesg | grep -c 'I/O error'").Trim())
    Write-Host ("dmesg 'I/O error' lines during this session: {0}  (should be 0, or equal to failed copy commands)" -f ($ioNow - $Script:IoBase)) -ForegroundColor Cyan
}

# ---------- phases ----------
$phases = switch ($Phase) {
    'Smoke'    { @('Smoke') }
    'Main'     { @('Main') }
    'Sweep'    { @('Sweep') }
    'FgImpact' { @('FgImpact') }
    'All'      { @('Smoke', 'Main', 'Sweep', 'FgImpact') }
}
$Script:IoBase = [int]((AdbShell "dmesg | grep -c 'I/O error'").Trim())

foreach ($p in $phases) {
    switch ($p) {
        'Smoke'    { Invoke-Bench 'smoke'    @{ NSEG = 256;   REPS = 1;     KEEPS = '4';     PATTERNS = 'contig'; FGIO = 0 } }
        'Main'     { Invoke-Bench 'main'     @{ NSEG = $Nseg; REPS = $Reps; KEEPS = '4';     PATTERNS = 'contig'; FGIO = 0 } }
        'Sweep'    { Invoke-Bench 'sweep'    @{ NSEG = $Nseg; REPS = $Reps; KEEPS = '2 4 6'; PATTERNS = 'contig alt'; FGIO = 0 } }
        'FgImpact' { Invoke-Bench 'fgimpact' @{ NSEG = $Nseg; REPS = $Reps; KEEPS = '4';     PATTERNS = 'contig'; FGIO = 1 } }
    }
}

Step 'Finished'
Write-Host "Results in: $OutDir" -ForegroundColor Green
