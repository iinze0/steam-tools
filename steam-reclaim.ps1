#Requires -Version 5.1
param(
  [string]$Steam,
  [switch]$Apply,
  [switch]$Yes
)

function Get-SteamRoot {
  if ($Steam -and (Test-Path -LiteralPath (Join-Path $Steam 'steamapps'))) { return (Resolve-Path $Steam).Path }
  if ($env:STEAM_PATH -and (Test-Path -LiteralPath (Join-Path $env:STEAM_PATH 'steamapps'))) { return $env:STEAM_PATH }
  foreach ($Key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
    if (-not (Test-Path $Key)) { continue }
    $Props = Get-ItemProperty $Key -ErrorAction SilentlyContinue
    foreach ($Name in @('SteamPath', 'InstallPath')) {
      $Value = $Props.$Name
      if (-not $Value) { continue }
      $Value = $Value -replace '/', '\'
      if (Test-Path -LiteralPath (Join-Path $Value 'steamapps')) { return $Value }
    }
  }
  foreach ($Guess in @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam")) {
    if ($Guess -and (Test-Path -LiteralPath (Join-Path $Guess 'steamapps'))) { return $Guess }
  }
  return $null
}

function Get-VdfValue([string]$Text, [string]$Key) {
  $Match = [regex]::Match($Text, '"' + [regex]::Escape($Key) + '"\s+"([^"]*)"')
  if ($Match.Success) { return $Match.Groups[1].Value }
  return $null
}

function Get-VdfValues([string]$Text, [string]$Key) {
  $Out = @()
  foreach ($Match in [regex]::Matches($Text, '"' + [regex]::Escape($Key) + '"\s+"([^"]*)"')) {
    $Out += $Match.Groups[1].Value
  }
  return $Out
}

function Get-FolderSize([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }
  $Sum = (Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum).Sum
  if ($null -eq $Sum) { return [int64]0 }
  return [int64]$Sum
}

function Format-Size([int64]$N) {
  if ($N -ge 1TB) { return ('{0:N1} TB' -f ($N / 1TB)) }
  if ($N -ge 1GB) { return ('{0:N1} GB' -f ($N / 1GB)) }
  if ($N -ge 1MB) { return ('{0:N1} MB' -f ($N / 1MB)) }
  if ($N -ge 1KB) { return ('{0:N1} KB' -f ($N / 1KB)) }
  return "$N B"
}

$Root = Get-SteamRoot
if (-not $Root) {
  Write-Error 'Steam not found. Set STEAM_PATH or pass -Steam "C:\Path\To\Steam"'
  exit 2
}

$Libraries = New-Object System.Collections.Generic.List[string]
[void]$Libraries.Add($Root)
$VdfPath = Join-Path $Root 'steamapps\libraryfolders.vdf'
if (Test-Path -LiteralPath $VdfPath) {
  $Vdf = Get-Content -LiteralPath $VdfPath -Raw -ErrorAction SilentlyContinue
  foreach ($P in (Get-VdfValues $Vdf 'path')) {
    $Clean = ($P -replace '\\', '\')
    if ((Test-Path -LiteralPath (Join-Path $Clean 'steamapps')) -and -not $Libraries.Contains($Clean)) {
      [void]$Libraries.Add($Clean)
    }
  }
}

Write-Host 'Libraries'
foreach ($Lib in $Libraries) { Write-Host "  $Lib" }
Write-Host ''

$KeepCommon = @('steam.dll', 'steamworks shared')
$KeepApp = @{'0' = $true; '228980' = $true }
$InstallDirByLib = @{}
$AppCount = 0

foreach ($Lib in $Libraries) {
  $Key = $Lib.ToLower()
  if (-not $InstallDirByLib.ContainsKey($Key)) { $InstallDirByLib[$Key] = @{} }
  Get-ChildItem -LiteralPath (Join-Path $Lib 'steamapps') -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue | ForEach-Object {
    $Text = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
    $AppId = Get-VdfValue $Text 'appid'
    $Dir = Get-VdfValue $Text 'installdir'
    if ($AppId) { $KeepApp[$AppId] = $true; $AppCount++ }
    if ($Dir) { $InstallDirByLib[$Key][$Dir.ToLower()] = $true }
  }
}

Write-Host "Installed apps: $AppCount"
Write-Host ''

$Orphans = @()
foreach ($Lib in $Libraries) {
  $Apps = Join-Path $Lib 'steamapps'
  $Owned = $InstallDirByLib[$Lib.ToLower()]
  $Common = Join-Path $Apps 'common'
  if (Test-Path -LiteralPath $Common) {
    Get-ChildItem -LiteralPath $Common -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $Name = $_.Name.ToLower()
      if ($KeepCommon -contains $Name) { return }
      if ($Owned.ContainsKey($Name)) { return }
      $Orphans += [pscustomobject]@{ Kind = 'common'; Path = $_.FullName; Bytes = Get-FolderSize $_.FullName }
    }
  }
  foreach ($Bucket in @('shadercache', 'compatdata')) {
    $Dir = Join-Path $Apps $Bucket
    if (-not (Test-Path -LiteralPath $Dir)) { continue }
    Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.Name -notmatch '^\d+$') { return }
      if ($KeepApp.ContainsKey($_.Name)) { return }
      $Orphans += [pscustomobject]@{ Kind = $Bucket; Path = $_.FullName; Bytes = Get-FolderSize $_.FullName }
    }
  }
}

$Orphans = @($Orphans | Sort-Object Bytes -Descending)
if ($Orphans.Count -eq 0) {
  Write-Host 'Nothing leftover. Steam is clean.'
  exit 0
}

$Total = [int64]($Orphans | Measure-Object Bytes -Sum).Sum
'{0,10}  {1,-12}  {2}' -f 'SIZE', 'TYPE', 'PATH'
'{0,10}  {1,-12}  {2}' -f ('-' * 10), ('-' * 12), ('-' * 40)
foreach ($Row in $Orphans) {
  '{0,10}  {1,-12}  {2}' -f (Format-Size $Row.Bytes), $Row.Kind, $Row.Path
}
Write-Host ''
Write-Host "$($Orphans.Count) leftover path(s) · $(Format-Size $Total) reclaimable"

if (-not $Apply) {
  Write-Host ''
  Write-Host 'Delete nothing yet. Re-run with -Apply to reclaim.'
  exit 0
}

if (-not $Yes) {
  $Answer = Read-Host "Delete $($Orphans.Count) path(s) ($(Format-Size $Total))? [y/N]"
  if ($Answer -notin @('y', 'Y', 'yes', 'YES')) {
    Write-Host 'aborted'
    exit 1
  }
}

foreach ($Row in $Orphans) {
  try {
    Remove-Item -LiteralPath $Row.Path -Recurse -Force -ErrorAction Stop
    Write-Host "removed $($Row.Path)"
  } catch {
    Write-Host "failed $($Row.Path): $_"
  }
}
