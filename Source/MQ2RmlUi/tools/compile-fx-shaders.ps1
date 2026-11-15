# Stage 1 GPU particles: shaders\fx.hlsl -> src\shaders_fx_bytecode.h (vs_5_0/ps_5_0, embedded in the DLL)
# and tools\fxsim_test\fx_test_bytecode.h (adds the cs_5_0 proof kernels). Fails on any fxc error/warning.
param([string]$Fxc = '')
$ErrorActionPreference = 'Stop'
# Plugin root = parent of tools\
$here = Split-Path -Parent $PSScriptRoot
if (-not $Fxc -or -not (Test-Path $Fxc)) {
  $Fxc = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\fxc.exe" -ErrorAction SilentlyContinue |
    Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Fxc) { throw 'fxc.exe not found (install a Windows 10/11 SDK)' }
$fxc = $Fxc
$hlsl = Join-Path $here 'shaders\fx.hlsl'
$tmp = Join-Path $env:TEMP 'mq2rmlui-fx-cso'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Build-Header([string]$outH, $entries) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('#pragma once')
  [void]$sb.AppendLine('// Generated from shaders/fx.hlsl by compile-fx-shaders.ps1 (fxc /O3, SM 5.0). Do not edit.')
  foreach ($e in $entries) {
    $cso = Join-Path $tmp "$($e.name).cso"
    $out = & $fxc /nologo /O3 /WX /T $e.profile /E $e.name /Fo $cso $hlsl 2>&1
    if ($LASTEXITCODE -ne 0) { $out | ForEach-Object { Write-Host $_ }; throw "fxc failed for $($e.name)" }
    $bytes = [IO.File]::ReadAllBytes($cso)
    Write-Host ("{0,-12} {1}  {2} bytes" -f $e.name, $e.profile, $bytes.Length)
    $sym = 'kBC_' + $e.name
    [void]$sb.AppendLine("static const unsigned char $sym[] = {")
    for ($i = 0; $i -lt $bytes.Length; $i += 16) {
      $chunk = $bytes[$i..([Math]::Min($i + 15, $bytes.Length - 1))]
      $hex = ($chunk | ForEach-Object { '0x{0:X2}' -f $_ }) -join ', '
      $suffix = if ($i + 16 -lt $bytes.Length) { ',' } else { '' }
      [void]$sb.AppendLine("  $hex$suffix")
    }
    [void]$sb.AppendLine('};')
    [void]$sb.AppendLine("static const unsigned ${sym}_len = sizeof($sym);")
    [void]$sb.AppendLine('')
  }
  [IO.File]::WriteAllText($outH, $sb.ToString())
  Write-Host "Wrote $outH"
}

$draw = @(@{ name = 'vs_fx'; profile = 'vs_5_0' }, @{ name = 'ps_fx'; profile = 'ps_5_0' }, @{ name = 'ps_bloom_mask'; profile = 'ps_5_0' })
Build-Header (Join-Path $here 'src\shaders_fx_bytecode.h') $draw
$testDir = Join-Path $here 'tools\fxsim_test'
if (Test-Path $testDir) {
  Build-Header (Join-Path $testDir 'fx_test_bytecode.h') ($draw + @(@{ name = 'cs_fx_eval'; profile = 'cs_5_0' }, @{ name = 'cs_fx_mask'; profile = 'cs_5_0' }))
}
