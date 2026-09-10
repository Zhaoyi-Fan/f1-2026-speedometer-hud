param(
  [string]$AcRoot = "D:\Program Files (x86)\Steam\steamapps\common\assettocorsa"
)
# Copies apps\lua\f1_2026_speedometer_hud from this repository into the Assetto Corsa install (overwrites).
$repo = Split-Path -Parent $PSScriptRoot
$src = Join-Path $repo "apps\lua\f1_2026_speedometer_hud"
$dst = Join-Path $AcRoot "apps\lua\f1_2026_speedometer_hud"
if (-not (Test-Path $src)) { throw "source missing: $src" }
if (-not (Test-Path (Join-Path $AcRoot "acs.exe"))) { throw "not an Assetto Corsa root (acs.exe not found): $AcRoot" }
if (Test-Path $dst) { Remove-Item -Recurse -Force $dst }
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item (Join-Path $src "*") $dst -Recurse -Force
Get-ChildItem $dst -Recurse -File | ForEach-Object { "{0,8}  {1}" -f $_.Length, $_.FullName.Substring($AcRoot.Length + 1) }
