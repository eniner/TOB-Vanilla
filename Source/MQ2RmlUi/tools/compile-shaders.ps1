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
$hlsl = Join-Path $here 'shaders\canvas.hlsl'
$outH = Join-Path $here 'src\shaders_canvas_bytecode.h'
$entries = @(
  @{ name = 'vs_main'; profile = 'vs_4_0' },
  @{ name = 'vs_sprite'; profile = 'vs_4_0' },
  @{ name = 'ps_color'; profile = 'ps_4_0' },
  @{ name = 'ps_blur'; profile = 'ps_4_0' },
  @{ name = 'ps_tex'; profile = 'ps_4_0' },
  @{ name = 'ps_downsample'; profile = 'ps_4_0' },
  @{ name = 'ps_bg'; profile = 'ps_4_0' },
  @{ name = 'ps_sprite'; profile = 'ps_4_0' },
  @{ name = 'ps_sprite_sq'; profile = 'ps_4_0' },
  @{ name = 'vs_sprite_ex'; profile = 'vs_4_0' },
  @{ name = 'ps_sprite_tex'; profile = 'ps_4_0' },
  @{ name = 'ps_composite'; profile = 'ps_4_0' }
)

$tmp = Join-Path $env:TEMP 'mq2rmlui-canvas-cso'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('#pragma once')
[void]$sb.AppendLine('// Generated from shaders/canvas.hlsl via fxc /Tvs_4_0|/Tps_4_0. Do not edit.')

function Emit-Array([string]$sym, [byte[]]$bytes) {
  [void]$script:sb.AppendLine("static const unsigned char $sym[] = {")
  for ($i = 0; $i -lt $bytes.Length; $i += 16) {
    $chunk = $bytes[$i..([Math]::Min($i + 15, $bytes.Length - 1))]
    $hex = ($chunk | ForEach-Object { '0x{0:X2}' -f $_ }) -join ', '
    $suffix = if ($i + 16 -lt $bytes.Length) { ',' } else { '' }
    [void]$script:sb.AppendLine("  $hex$suffix")
  }
  [void]$script:sb.AppendLine('};')
  [void]$script:sb.AppendLine("static const unsigned ${sym}_len = sizeof($sym);")
  [void]$script:sb.AppendLine('')
}

foreach ($e in $entries) {
  $cso = Join-Path $tmp "$($e.name).cso"
  & $fxc /nologo /O3 /T $e.profile /E $e.name /Fo $cso $hlsl
  if ($LASTEXITCODE -ne 0) { throw "fxc failed for $($e.name)" }
  $bytes = [IO.File]::ReadAllBytes($cso)
  Write-Host ("{0}  {1} bytes" -f $e.name, $bytes.Length)
  Emit-Array ("kBC_" + $e.name) $bytes
}

[IO.File]::WriteAllText($outH, $sb.ToString())
Write-Host "Wrote $outH"
