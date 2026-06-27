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
  try {
    Invoke-CheckedCommand $winget.Source @(
      'install',
      '--id',
      'Cloudflare.cloudflared',
      '-e',
      '--accept-package-agreements',
      '--accept-source-agreements'
    ) 'logs\cloudflared-install.log' | Out-Null
  } catch {
    $listOutput = & $winget.Source list --id Cloudflare.cloudflared -e 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (($listOutput -join "`n") -match 'Cloudflare\.cloudflared')) {
      throw
    }

    Write-Warning "winget returned a non-zero code, but Cloudflare.cloudflared is already installed. Continuing."
  }

  $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "$machinePath;$userPath"
  $cloudflaredPath = Find-CloudflaredExecutable
  if ($null -ne $cloudflaredPath) {
    Add-ToProcessPath (Split-Path -Parent $cloudflaredPath)
    Write-Host "cloudflared is available: $cloudflaredPath"
  } else {
    Write-Warning 'cloudflared appears installed by winget, but cloudflared.exe was not found in common locations.'
  }

  Write-Host 'cloudflared installation check finished.'
  exit 0
}

Write-Host 'cloudflared was not found.'
Write-Host 'Install it with one of these options:'
Write-Host '  .\scripts\install-cloudflared.ps1 -UseWinget'
Write-Host '  or download it from https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/'
