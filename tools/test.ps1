<#
.SYNOPSIS
Parse the HUD's Lua files and optionally execute one pure-Lua stub test.
.DESCRIPTION
Supply an existing MoonSharp DLL; this script does not download or copy runtimes.
On 64-bit Windows it relaunches itself in x86 Windows PowerShell for runtimes that
need that host. Syntax parsing does not execute the HUD or access the game.
Optional tests receive HUD_SOURCE, HUD_DATA_SOURCE, loadHud(), loadHudData(), and
package.preload.hud_data. Stub CSP globals before calling loadHud().
Example: ./tools/test.ps1 -MoonSharpDll <existing-dll> -TestFile <test.lua>
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$MoonSharpDll,
  [string]$TestFile,
  [switch]$SyntaxOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($SyntaxOnly -and $TestFile) { throw 'Choose -SyntaxOnly or -TestFile, not both.' }
$dllPath = [IO.Path]::GetFullPath($MoonSharpDll)
if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) { throw "MoonSharp DLL not found: $dllPath" }
$testPath = if ($TestFile) { [IO.Path]::GetFullPath($TestFile) } else { $null }
if ($testPath -and -not (Test-Path -LiteralPath $testPath -PathType Leaf)) { throw "Test file not found: $testPath" }
if ([IntPtr]::Size -ne 4) {
  $x86PowerShell = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path -LiteralPath $x86PowerShell -PathType Leaf)) { throw 'An x86 Windows PowerShell host is required by this runner.' }
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-MoonSharpDll', $dllPath)
  if ($testPath) { $arguments += @('-TestFile', $testPath) }
  if ($SyntaxOnly) { $arguments += '-SyntaxOnly' }
  & $x86PowerShell @arguments
  if ($LASTEXITCODE -ne 0) { throw "Lua validation failed (exit $LASTEXITCODE)." }
  return
}

try {
  [Reflection.Assembly]::LoadFrom($dllPath) | Out-Null
  $appDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'apps\lua\f1_2026_speedometer_hud'
  $luaFiles = @(Get-ChildItem -LiteralPath $appDirectory -Filter '*.lua' -File | Sort-Object Name)
  if ($luaFiles.Count -eq 0) { throw "No Lua source files found in $appDirectory" }
  $parser = New-Object MoonSharp.Interpreter.Script
  foreach ($file in $luaFiles) {
    $parser.LoadString([IO.File]::ReadAllText($file.FullName), $null, $file.Name) | Out-Null
    Write-Output "Syntax OK: $($file.Name)"
  }
  if ($testPath) {
    $runtime = New-Object MoonSharp.Interpreter.Script
    $runtime.Options.DebugPrint = [Action[string]]{ param($line) [Console]::WriteLine($line) }
    $runtime.Globals.Set('HUD_SOURCE', [MoonSharp.Interpreter.DynValue]::NewString([IO.File]::ReadAllText((Join-Path $appDirectory 'f1_2026_speedometer_hud.lua'))))
    $runtime.Globals.Set('HUD_DATA_SOURCE', [MoonSharp.Interpreter.DynValue]::NewString([IO.File]::ReadAllText((Join-Path $appDirectory 'hud_data.lua'))))
    $prelude = @'
function loadHud() return assert(load(HUD_SOURCE, 'f1_2026_speedometer_hud.lua'))() end
function loadHudData() return assert(load(HUD_DATA_SOURCE, 'hud_data.lua'))() end
package = package or {}
package.preload = package.preload or {}
package.loaded = package.loaded or {}
package.preload.hud_data = loadHudData
local originalRequire = require
function require(name)
  if package.loaded[name] ~= nil then return package.loaded[name] end
  if package.preload[name] then
    local result = package.preload[name]()
    if result == nil then result = true end
    package.loaded[name] = result
    return result
  end
  return originalRequire(name)
end
'@
    $runtime.DoString($prelude, $null, 'runner_prelude') | Out-Null
    $runtime.DoString([IO.File]::ReadAllText($testPath), $null, [IO.Path]::GetFileName($testPath)) | Out-Null
    Write-Output "Test OK: $([IO.Path]::GetFileName($testPath))"
  }
} catch {
  $failure = $_.Exception
  while ($failure.InnerException) { $failure = $failure.InnerException }
  $decorated = $failure.PSObject.Properties['DecoratedMessage']
  $message = if ($decorated -and $decorated.Value) { $decorated.Value } else { $failure.Message }
  [Console]::Error.WriteLine("Lua validation failed: $message")
  exit 1
}
