[CmdletBinding()]
param(
  [switch] $UseWinget
)

. "$PSScriptRoot\lib.ps1"

$existing = Get-Command cloudflared -ErrorAction SilentlyContinue
if ($null -ne $existing) {
  Write-Host "cloudflared is already installed: $($existing.Source)"
  exit 0
}

if ($UseWinget) {
  $winget = Get-RequiredCommand 'winget'
  Invoke-CheckedCommand $winget.Source @(
    'install',
    '--id',
    'Cloudflare.cloudflared',
    '-e',
    '--accept-package-agreements',
    '--accept-source-agreements'
  ) 'logs\cloudflared-install.log' | Out-Null
  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "$machinePath;$userPath"
  Write-Host 'cloudflared installation requested through winget.'
  exit 0
}

Write-Host 'cloudflared was not found.'
Write-Host 'Install it with one of these options:'
Write-Host '  .\scripts\install-cloudflared.ps1 -UseWinget'
Write-Host '  or download it from https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/'
