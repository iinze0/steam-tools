#Requires -Version 5.1
param(
  [Parameter(Position = 0)][string]$Query,
  [switch]$List,
  [switch]$Size,
  [ValidateSet('steam', 'epic')]$Store,
  [switch]$Path,
  [switch]$All
)

function Get-SteamRoot {
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
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return [int64]0 }
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

$SkipName = 'steamworks|proton |proton$|runtime|dedicated server|steam linux|steamworks common'
$Games = @()

$Root = Get-SteamRoot
if ($Root) {
  $Libs = New-Object System.Collections.Generic.List[string]
  [void]$Libs.Add($Root)
  $VdfPath = Join-Path $Root 'steamapps\libraryfolders.vdf'
  if (Test-Path -LiteralPath $VdfPath) {
    $Vdf = Get-Content -LiteralPath $VdfPath -Raw
    foreach ($P in ([regex]::Matches($Vdf, '"path"\s+"([^"]*)"') | ForEach-Object { $_.Groups[1].Value -replace '\\', '\' })) {
      if ((Test-Path -LiteralPath (Join-Path $P 'steamapps')) -and -not $Libs.Contains($P)) { [void]$Libs.Add($P) }
    }
  }
  $Seen = @{}
  foreach ($Lib in $Libs) {
    Get-ChildItem -LiteralPath (Join-Path $Lib 'steamapps') -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue | ForEach-Object {
      $Text = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
      $AppId = Get-VdfValue $Text 'appid'
      $Name = Get-VdfValue $Text 'name'
      $Install = Get-VdfValue $Text 'installdir'
      $Disk = Get-VdfValue $Text 'SizeOnDisk'
      if (-not $AppId -or -not $Name -or $Seen.ContainsKey($AppId)) { return }
      $Seen[$AppId] = $true
      $InstallPath = $null
      if ($Install) {
        $Candidate = Join-Path $Lib "steamapps\common\$Install"
        if (Test-Path -LiteralPath $Candidate) { $InstallPath = $Candidate }
      }
      $Bytes = 0
      if ($Disk) { [int64]::TryParse($Disk, [ref]$Bytes) | Out-Null }
      if ($Bytes -le 0 -and $InstallPath) { $Bytes = Get-FolderSize $InstallPath }
      $Games += [pscustomobject]@{
        Store = 'steam'; Name = $Name; Key = $AppId; Path = $InstallPath; Bytes = $Bytes; SteamRoot = $Root
      }
    }
  }
}

$EpicManifests = 'C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests'
if (Test-Path -LiteralPath $EpicManifests) {
  Get-ChildItem -LiteralPath $EpicManifests -Filter '*.item' -File -ErrorAction SilentlyContinue | ForEach-Object {
    try { $Row = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json } catch { return }
    if (-not $Row.AppName) { return }
    $InstallPath = $Row.InstallLocation
    $Bytes = 0
    if ($Row.InstallSize) { $Bytes = [int64]$Row.InstallSize }
    if ($Bytes -le 0 -and $InstallPath) { $Bytes = Get-FolderSize $InstallPath }
    $Games += [pscustomobject]@{
      Store = 'epic'; Name = $(if ($Row.DisplayName) { $Row.DisplayName } else { $Row.AppName }); Key = $Row.AppName; Path = $InstallPath; Bytes = $Bytes; SteamRoot = $null
    }
  }
}

if (-not $All) {
  $Games = @($Games | Where-Object { $_.Name -notmatch $SkipName })
}
if ($Store) {
  $Games = @($Games | Where-Object { $_.Store -eq $Store })
}
if ($Size) {
  $Games = @($Games | Sort-Object Bytes -Descending)
} else {
  $Games = @($Games | Sort-Object Name)
}

function Show-List($Rows) {
  if ($Rows.Count -eq 0) {
    Write-Host 'No games found.'
    return
  }
  '{0,10}  {1,-6}  {2}' -f 'SIZE', 'STORE', 'GAME'
  '{0,10}  {1,-6}  {2}' -f ('-' * 10), ('-' * 6), ('-' * 32)
  foreach ($G in $Rows) {
    '{0,10}  {1,-6}  {2}' -f (Format-Size $G.Bytes), $G.Store, $G.Name
  }
  $SteamN = @($Rows | Where-Object Store -eq 'steam').Count
  $EpicN = @($Rows | Where-Object Store -eq 'epic').Count
  $Total = [int64]($Rows | Measure-Object Bytes -Sum).Sum
  Write-Host ''
  Write-Host "$($Rows.Count) game(s) · $SteamN Steam · $EpicN Epic · $(Format-Size $Total)"
}

if ($Query) {
  $Q = $Query.ToLower()
  $Hits = @($Games | Where-Object { $_.Name.ToLower() -eq $Q -or $_.Key.ToLower() -eq $Q })
  if ($Hits.Count -eq 0) {
    $Hits = @($Games | Where-Object { $_.Name.ToLower().Contains($Q) -or $_.Key.ToLower().Contains($Q) })
  }
  if ($Hits.Count -eq 0) {
    Write-Error "no match for $Query"
    exit 1
  }
  if ($List -or ($Hits.Count -gt 1 -and -not $Path)) {
    Show-List $Hits
    if ($Hits.Count -gt 1 -and -not $List) { Write-Host "`nbe more specific to launch" }
    exit 0
  }
  $Game = $Hits[0]
  if ($Path) {
    if ($Game.Path) { Write-Output $Game.Path; exit 0 }
    Write-Error "no install path for $($Game.Name)"
    exit 1
  }
  Write-Host "launch $($Game.Store):$($Game.Name)"
  if ($Game.Store -eq 'steam') {
    $Exe = Join-Path $Game.SteamRoot 'steam.exe'
    if (Test-Path -LiteralPath $Exe) {
      Start-Process -FilePath $Exe -ArgumentList @('-applaunch', $Game.Key)
    } else {
      Start-Process "steam://rungameid/$($Game.Key)"
    }
    exit 0
  }
  Start-Process "com.epicgames.launcher://apps/$($Game.Key)?action=launch&silent=true"
  exit 0
}

Show-List $Games
