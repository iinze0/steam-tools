#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$Dest = Join-Path $env:LOCALAPPDATA 'iinze0\bin'
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

$Base = 'https://raw.githubusercontent.com/iinze0/steam-tools/main'
$Files = @('steam-reclaim.ps1', 'steam-saves.ps1', 'shelf.ps1', 'steam-reclaim.cmd', 'steam-saves.cmd', 'shelf.cmd')

$Here = $PSScriptRoot
foreach ($Name in $Files) {
  $Target = Join-Path $Dest $Name
  $Local = if ($Here) { Join-Path $Here $Name } else { $null }
  if ($Local -and (Test-Path -LiteralPath $Local)) {
    Copy-Item -LiteralPath $Local -Destination $Target -Force
  } else {
    Invoke-WebRequest -UseBasicParsing -Uri "$Base/$Name" -OutFile $Target
  }
}

$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $UserPath) { $UserPath = '' }
$Parts = @($UserPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
if ($Parts -notcontains $Dest) {
  $NewPath = ($Parts + $Dest) -join ';'
  [Environment]::SetEnvironmentVariable('Path', $NewPath, 'User')
}
$env:Path = $Dest + ';' + $env:Path

Write-Host "Installed to $Dest"
Write-Host 'Open a new terminal, then run:  steam-reclaim   steam-saves   shelf'
