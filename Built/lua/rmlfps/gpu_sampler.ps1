# rmlfps GPU sampler (v4). Started hidden + idle priority by rmlfps/init.lua; one per rmlfps run.
# Writes one tiny line per second into the shared-memory block $Map that rmlfps created (no files anywhere).
# Exits by itself when eqgame exits, when rmlfps sets the stop flag, or when its heartbeat stops for 20 s (long zone loads stall the game thread).
# Block layout (uint32 words): [0] heartbeat from rmlfps, [1] stop flag, [2] seq (odd while writing), [3] length, bytes 16.. line.
param([int]$ParentPid, [string]$Map, [int]$MaxSeconds = 0)
$ErrorActionPreference = 'SilentlyContinue'
try { [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'Idle' } catch {}
$mm = $null; $acc = $null
try { $mm = [IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($Map); $acc = $mm.CreateViewAccessor(0, 256) } catch { [Environment]::Exit(1) }
$seq = [uint32]0; $lastHb = $acc.ReadUInt32(0); $hbT = Get-Date
$pfx = "pid_$($ParentPid)_"
# total VRAM: the display adapter's qwMemorySize (Win32_VideoController.AdapterRAM is capped at 4 GB)
$vt = 0
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}' | ForEach-Object {
  $q = (Get-ItemProperty $_.PSPath).'HardwareInformation.qwMemorySize'
  if ($q -and [uint64]$q -gt $vt) { $vt = [uint64]$q } }
$paths = @(
  "\GPU Engine(*engtype_3D)\Utilization Percentage",
  "\GPU Process Memory($($pfx)*)\Dedicated Usage",
  "\GPU Adapter Memory(*)\Dedicated Usage")
$inv = [Globalization.CultureInfo]::InvariantCulture
$t0 = Get-Date
$n = 0
Get-Counter -Counter $paths -SampleInterval 1 -Continuous | ForEach-Object {
  $gp = 0.0; $gt = 0.0; $vp = 0.0; $vu = 0.0; $byLuid = @{}
  foreach ($s in $_.CounterSamples) {
    $p = $s.Path; $v = $s.CookedValue; $i = $s.InstanceName
    if ($p -like '*\utilization percentage') {
      # 3D load per adapter (luid); total = the busiest adapter, like Task Manager's GPU 3D graph
      $l = ''; $k = $i.IndexOf('_luid_'); if ($k -ge 0 -and $i.Length -ge $k + 27) { $l = $i.Substring($k + 6, 21) }
      $byLuid[$l] = [double]$byLuid[$l] + $v
      if ($i.StartsWith($pfx)) { $gp += $v } }
    elseif ($p -like '*gpu process memory*') { $vp += $v }
    elseif ($p -like '*gpu adapter memory*') { if ($v -gt $vu) { $vu = $v } }
  }
  foreach ($x in $byLuid.Values) { if ($x -gt $gt) { $gt = $x } }
  if ($gt -gt 100) { $gt = 100 }; if ($gp -gt 100) { $gp = 100 }
  $n++
  $line = [string]::Format($inv, 'rmlfps1 n={0} gp={1:F1} gt={2:F1} vp={3:F0} vu={4:F0} vt={5:F0} end', $n, $gp, $gt, ($vp/1MB), ($vu/1MB), ($vt/1MB))
  $alive = $null -ne (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)
  $hb = $acc.ReadUInt32(0); if ($hb -ne $lastHb) { $lastHb = $hb; $hbT = Get-Date }
  $stop = $acc.ReadUInt32(4) -ne 0
  $b = [Text.Encoding]::ASCII.GetBytes($line)
  $seq = [uint32](($seq + 1) % 4294967296); $acc.Write(8, $seq)              # odd: writing
  $acc.WriteArray(16, $b, 0, $b.Length); $acc.Write(12, [uint32]$b.Length)
  $seq = [uint32](($seq + 1) % 4294967296); $acc.Write(8, $seq)              # even: complete
  if (-not $alive -or $stop -or ((Get-Date) - $hbT).TotalSeconds -ge 20 -or ($MaxSeconds -gt 0 -and ((Get-Date) - $t0).TotalSeconds -ge $MaxSeconds)) {
    try { $acc.Dispose(); $mm.Dispose() } catch {}
    [Environment]::Exit(0)
  }
}
