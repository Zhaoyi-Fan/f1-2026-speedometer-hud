<#
.SYNOPSIS
Back up and replace only the HUD's managed files, or restore one deployment.
.DESCRIPTION
Requires Assetto Corsa to be closed. BackupRoot must be outside the repository and
the game installation. Unknown files and user settings are never copied or removed.
Use -RetireNativeProbe only when the production HUD no longer loads native_probe.
Every deployment creates deployment.json with before/after SHA-256 hashes.
Rollback: ./tools/deploy.ps1 -AcRoot <game> -RestoreManifest <deployment.json>
Rollback refuses to overwrite files changed after deployment. Empty directories
are retained. This script never deletes an app directory.
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
  [Parameter(Mandatory = $true)][string]$AcRoot,
  [Parameter(Mandatory = $true, ParameterSetName = 'Install')][string]$BackupRoot,
  [Parameter(ParameterSetName = 'Install')][switch]$RetireNativeProbe,
  [Parameter(Mandatory = $true, ParameterSetName = 'Restore')][string]$RestoreManifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$managedFiles = @('f1_2026_speedometer_hud.lua', 'hud_data.lua', 'manifest.ini')
$allowedFiles = @($managedFiles) + 'native_probe.lua'
$repo = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$gameRoot = [IO.Path]::GetFullPath($AcRoot).TrimEnd('\', '/')
$sourceRoot = Join-Path $repo 'apps\lua\f1_2026_speedometer_hud'
$destinationRoot = Join-Path $gameRoot 'apps\lua\f1_2026_speedometer_hud'

function Assert-GameClosed {
  $running = @(Get-Process -Name acs, acs_x86 -ErrorAction SilentlyContinue)
  if ($running.Count -gt 0) { throw 'Close Assetto Corsa before installing or restoring the HUD.' }
}

function Test-Within([string]$Path, [string]$Parent) {
  $normalized = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
  $boundary = [IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
  return $normalized.Equals($boundary, [StringComparison]::OrdinalIgnoreCase) -or
    $normalized.StartsWith($boundary + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-PlainPath([string]$Path) {
  # Refuse junction/symlink traversal, including existing ancestor directories.
  $cursor = [IO.Path]::GetFullPath($Path)
  while ($cursor) {
    if (Test-Path -LiteralPath $cursor) {
      $item = Get-Item -LiteralPath $cursor -Force
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse points are not supported for deployment: $cursor"
      }
    }
    $parent = Split-Path -Parent $cursor
    if ($parent -eq $cursor) { break }
    $cursor = $parent
  }
}

function Get-FileDigest([string]$Path) {
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
  }
  if (Test-Path -LiteralPath $Path) { throw "Expected a file, found a directory: $Path" }
  return $null
}

function Write-Manifest($Manifest, [string]$Path) {
  [IO.File]::WriteAllText($Path, ($Manifest | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}

Assert-GameClosed
Assert-PlainPath $gameRoot
Assert-PlainPath $destinationRoot
if (-not (Test-Path -LiteralPath (Join-Path $gameRoot 'acs.exe') -PathType Leaf)) {
  throw "Not an Assetto Corsa root (acs.exe missing): $gameRoot"
}

if ($PSCmdlet.ParameterSetName -eq 'Restore') {
  $manifestPath = [IO.Path]::GetFullPath($RestoreManifest)
  Assert-PlainPath $manifestPath
  $backupDirectory = Split-Path -Parent $manifestPath
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if ($manifest.schema -ne 1 -or $manifest.app -ne 'f1_2026_speedometer_hud' -or
      $manifest.acRoot -ne $gameRoot -or $manifest.destination -ne $destinationRoot) {
    throw 'Manifest schema, app or installation path does not match this restore request.'
  }
  $entries = @($manifest.files)
  if ($entries.Count -lt 3 -or $entries.Count -gt 4 -or
      @($entries.name | Select-Object -Unique).Count -ne $entries.Count) {
    throw 'Invalid managed-file list in deployment manifest.'
  }
  foreach ($entry in $entries) {
    if ($allowedFiles -notcontains $entry.name -or $entry.action -notin @('install', 'remove') -or
        ($entry.action -eq 'remove' -and $entry.name -ne 'native_probe.lua')) {
      throw 'Manifest contains an unsupported file or action.'
    }
    $target = Join-Path $destinationRoot $entry.name
    $backup = Join-Path $backupDirectory ('before\' + $entry.name)
    Assert-PlainPath $target
    Assert-PlainPath $backup
    if ($entry.beforeHash -and (Get-FileDigest $backup) -ne $entry.beforeHash) {
      throw "Missing or modified backup: $($entry.name)"
    }
    $currentHash = Get-FileDigest $target
    if ($currentHash -ne $entry.afterHash -and $currentHash -ne $entry.beforeHash) {
      throw "File changed after deployment; preserve and review it before restoring: $($entry.name)"
    }
  }
  # All backups and targets have been checked before the first restore write.
  Assert-GameClosed
  foreach ($entry in $entries) {
    $target = Join-Path $destinationRoot $entry.name
    if ($entry.beforeHash) {
      [IO.Directory]::CreateDirectory($destinationRoot) | Out-Null
      [IO.File]::Copy((Join-Path $backupDirectory ('before\' + $entry.name)), $target, $true)
    } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
      # The only removal is this verified, explicitly named managed file.
      Remove-Item -LiteralPath $target -Force
    }
    if ((Get-FileDigest $target) -ne $entry.beforeHash) { throw "Restore verification failed: $($entry.name)" }
  }
  [IO.File]::WriteAllText((Join-Path $backupDirectory 'restored.txt'), [DateTime]::UtcNow.ToString('o'))
  Write-Output "Restored managed files using $manifestPath"
  return
}

$backupBase = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\', '/')
if ((Test-Within $backupBase $repo) -or (Test-Within $backupBase $gameRoot)) {
  throw 'BackupRoot must be outside both the repository and the game installation.'
}
Assert-PlainPath $backupBase
Assert-PlainPath $sourceRoot
foreach ($name in $managedFiles) {
  $source = Join-Path $sourceRoot $name
  Assert-PlainPath $source
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Source missing: $source" }
}
if ($RetireNativeProbe -and (Select-String -LiteralPath (Join-Path $sourceRoot 'f1_2026_speedometer_hud.lua') -Pattern 'native_probe' -Quiet)) {
  throw 'The source HUD still refers to native_probe; remove its production integration before retiring it.'
}
$names = @($managedFiles)
if ($RetireNativeProbe) { $names += 'native_probe.lua' }
$entries = @()
foreach ($name in $names) {
  $target = Join-Path $destinationRoot $name
  Assert-PlainPath $target
  $action = if ($name -eq 'native_probe.lua') { 'remove' } else { 'install' }
  $afterHash = if ($action -eq 'install') { Get-FileDigest (Join-Path $sourceRoot $name) } else { $null }
  $entries += [pscustomobject]@{ name = $name; action = $action; beforeHash = (Get-FileDigest $target); afterHash = $afterHash }
}
$backupDirectory = Join-Path $backupBase ('hud-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
[IO.Directory]::CreateDirectory((Join-Path $backupDirectory 'before')) | Out-Null
$manifestPath = Join-Path $backupDirectory 'deployment.json'
foreach ($entry in $entries) {
  if ($entry.beforeHash) {
    $backup = Join-Path $backupDirectory ('before\' + $entry.name)
    [IO.File]::Copy((Join-Path $destinationRoot $entry.name), $backup, $false)
    if ((Get-FileDigest $backup) -ne $entry.beforeHash) { throw "Backup verification failed: $($entry.name)" }
  }
}
$manifest = [ordered]@{ schema = 1; app = 'f1_2026_speedometer_hud'; createdUtc = [DateTime]::UtcNow.ToString('o');
  acRoot = $gameRoot; destination = $destinationRoot; status = 'prepared'; files = $entries; applied = @() }
Write-Manifest $manifest $manifestPath
Write-Output "Verified backup and rollback manifest: $manifestPath"
try {
  Assert-GameClosed
  foreach ($entry in $entries) {
    if ((Get-FileDigest (Join-Path $destinationRoot $entry.name)) -ne $entry.beforeHash) {
      throw "Installation changed during backup: $($entry.name)"
    }
    if ($entry.action -eq 'install' -and (Get-FileDigest (Join-Path $sourceRoot $entry.name)) -ne $entry.afterHash) {
      throw "Source changed during backup: $($entry.name)"
    }
  }
  [IO.Directory]::CreateDirectory($destinationRoot) | Out-Null
  foreach ($entry in $entries) {
    $target = Join-Path $destinationRoot $entry.name
    if ($entry.action -eq 'install') {
      [IO.File]::Copy((Join-Path $sourceRoot $entry.name), $target, $true)
    } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
      Remove-Item -LiteralPath $target -Force
    }
    if ((Get-FileDigest $target) -ne $entry.afterHash) { throw "Install verification failed: $($entry.name)" }
    $manifest.applied += $entry.name
    Write-Manifest $manifest $manifestPath
  }
  $manifest.status = 'complete'
  Write-Manifest $manifest $manifestPath
} catch {
  $manifest.status = 'failed'
  Write-Manifest $manifest $manifestPath
  throw "Deployment stopped. Preserve the verified backup and restore with -RestoreManifest '$manifestPath'. $($_.Exception.Message)"
}
Write-Output "Installed and SHA-256 verified $($managedFiles.Count) managed files. Unrelated files and settings preserved."
if ($RetireNativeProbe) { Write-Output 'Retired native_probe.lua; historical CSV evidence was not touched.' }
