#Requires -Version 5.1
param(
  [Parameter(Position = 0)][ValidateSet('list', 'backup', 'restore')]$Command = 'list',
  [Parameter(Position = 1)][string]$Query,
  [string]$Steam,
  [string]$Dest,
  [string]$From
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

function Get-Slug([string]$Name, [string]$AppId) {
  $S = ($Name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
  if ($S) { return "$AppId-$S" }
  return $AppId
}

$Skip = @('7', '8', '760', '241100', 'config', 'ugc', 'inventory')
$Root = Get-SteamRoot
if (-not $Root) {
  Write-Error 'Steam not found. Set STEAM_PATH or pass -Steam'
  exit 2
}

$Names = @{}
Get-ChildItem -LiteralPath (Join-Path $Root 'steamapps') -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue | ForEach-Object {
  $Text = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
  $Id = Get-VdfValue $Text 'appid'
  $Name = Get-VdfValue $Text 'name'
  if ($Id -and $Name) { $Names[$Id] = $Name }
}
$LibVdf = Join-Path $Root 'steamapps\libraryfolders.vdf'
if (Test-Path -LiteralPath $LibVdf) {
  $Vdf = Get-Content -LiteralPath $LibVdf -Raw
  foreach ($P in ([regex]::Matches($Vdf, '"path"\s+"([^"]*)"') | ForEach-Object { $_.Groups[1].Value -replace '\\', '\' })) {
    $Apps = Join-Path $P 'steamapps'
    if (-not (Test-Path -LiteralPath $Apps)) { continue }
    Get-ChildItem -LiteralPath $Apps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue | ForEach-Object {
      $Text = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
      $Id = Get-VdfValue $Text 'appid'
      $Name = Get-VdfValue $Text 'name'
      if ($Id -and $Name) { $Names[$Id] = $Name }
    }
  }
}

$Items = @()
$UserData = Join-Path $Root 'userdata'
if (Test-Path -LiteralPath $UserData) {
  Get-ChildItem -LiteralPath $UserData -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' } | ForEach-Object {
    Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      if ($Skip -contains $_.Name) { return }
      if ($_.Name -notmatch '^\d+$') { return }
      $Remote = Join-Path $_.FullName 'remote'
      $Target = if (Test-Path -LiteralPath $Remote) { $Remote } else { $_.FullName }
      $Bytes = Get-FolderSize $Target
      if ($Bytes -le 0) { return }
      $AppId = $_.Name
      $Items += [pscustomobject]@{
        AppId = $AppId
        Name  = $(if ($Names.ContainsKey($AppId)) { $Names[$AppId] } else { "app $AppId" })
        Path  = $Target
        Bytes = $Bytes
      }
    }
  }
}

$Items = @($Items | Sort-Object Bytes -Descending)
if ($Query) {
  $Q = $Query.ToLower()
  $Items = @($Items | Where-Object { $_.AppId -eq $Query -or $_.Name.ToLower().Contains($Q) })
}

if ($Command -eq 'list') {
  if ($Items.Count -eq 0) { Write-Host 'No save folders found.'; exit 0 }
  '{0,10}  {1,-10}  {2}' -f 'SIZE', 'APPID', 'GAME'
  '{0,10}  {1,-10}  {2}' -f ('-' * 10), ('-' * 10), ('-' * 32)
  foreach ($Row in $Items) {
    '{0,10}  {1,-10}  {2}' -f (Format-Size $Row.Bytes), $Row.AppId, $Row.Name
  }
  $Total = [int64]($Items | Measure-Object Bytes -Sum).Sum
  Write-Host ''
  Write-Host "$($Items.Count) game(s) · $(Format-Size $Total) total"
  exit 0
}

if ($Command -eq 'backup') {
  if ($Items.Count -eq 0) { Write-Error 'nothing to backup'; exit 1 }
  if (-not $Dest) { $Dest = Join-Path $env:USERPROFILE ("SteamSaves\{0:yyyy-MM-dd}" -f (Get-Date)) }
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  foreach ($Row in $Items) {
    $GameDir = Join-Path $Dest (Get-Slug $Row.Name $Row.AppId)
    $Cloud = Join-Path $GameDir 'cloud'
    New-Item -ItemType Directory -Force -Path $Cloud | Out-Null
    Copy-Item -LiteralPath $Row.Path -Destination $Cloud -Recurse -Force
    Write-Host "backed up $($Row.Name) -> $GameDir"
  }
  Write-Host "`n$($Items.Count) game(s) in $Dest"
  exit 0
}

if ($Command -eq 'restore') {
  $Src = $From
  if (-not $Src) { $Src = $Dest }
  if (-not $Src -or -not (Test-Path -LiteralPath $Src)) {
    Write-Error 'pass -From C:\path\to\backup'
    exit 2
  }
  $Restored = 0
  Get-ChildItem -LiteralPath $Src -Directory | ForEach-Object {
    $AppId = ($_.Name -split '-', 2)[0]
    if ($AppId -notmatch '^\d+$') { return }
    $Cloud = Join-Path $_.FullName 'cloud'
    if (-not (Test-Path -LiteralPath $Cloud)) { return }
    Get-ChildItem -LiteralPath $UserData -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' } | ForEach-Object {
      $Target = Join-Path $_.FullName "$AppId\remote"
      New-Item -ItemType Directory -Force -Path $Target | Out-Null
      Copy-Item -Path (Join-Path $Cloud '*') -Destination $Target -Recurse -Force -ErrorAction SilentlyContinue
      Write-Host "restored cloud $AppId -> $Target"
      $Restored++
    }
  }
  Write-Host "`n$Restored restore path(s)"
  if ($Restored -eq 0) { exit 1 }
  exit 0
}
