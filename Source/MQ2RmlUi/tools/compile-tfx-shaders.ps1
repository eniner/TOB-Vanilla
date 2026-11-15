# TextFX (CombatFX theme numbers): shaders\tfx.hlsl -> src\shaders_tfx_bytecode.h (vs_5_0/ps_5_0, embedded in the DLL).
# Fails on any fxc error/warning (/WX).
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
$hlsl = Join-Path $here 'shaders\tfx.hlsl'
$tmp = Join-Path $env:TEMP 'mq2rmlui-tfx-cso'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function Build-Header([string]$outH, $entries) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('#pragma once')
  [void]$sb.AppendLine('// Generated from shaders/tfx.hlsl by compile-tfx-shaders.ps1 (fxc /O3, SM 5.0). Do not edit.')
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

$draw = @(@{ name = 'vs_tfx_glyph'; profile = 'vs_5_0' }, @{ name = 'ps_tfx_glyph'; profile = 'ps_5_0' }, @{ name = 'vs_tfx_part'; profile = 'vs_5_0' }, @{ name = 'ps_tfx_part'; profile = 'ps_5_0' })
Build-Header (Join-Path $here 'src\shaders_tfx_bytecode.h') $draw
