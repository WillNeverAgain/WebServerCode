[CmdletBinding()]
param(
  [switch] $NoRestart
)

. "$PSScriptRoot\lib.ps1"

$config = Get-SiteConfig
$gitConfig = Get-PropertyValue $config 'git' $null

$frameworkConfig = Get-PropertyValue $gitConfig 'framework' $null
$webConfig = Get-PropertyValue $gitConfig 'web' $null

$results = @()
$results += Update-GitRepository 'framework' $frameworkConfig '.' 'logs\git-update.log'
$results += Update-GitRepository 'web' $webConfig 'webapps\current' 'logs\git-update.log'

foreach ($result in $results) {
  $status = if ($result.Changed) { 'changed' } elseif ($result.Skipped) { 'skipped' } else { 'unchanged' }
  Write-Host "$($result.Name): $status ($($result.Message))"
}

$anyChanged = @($results | Where-Object { $_.Changed }).Count -gt 0
if (-not $anyChanged) {
  exit 0
}

$freshConfig = Get-SiteConfig
$freshGitConfig = Get-PropertyValue $freshConfig 'git' $null
$afterUpdate = Get-PropertyValue $freshGitConfig 'afterUpdate' $null
$restartServer = Get-PropertyValue $afterUpdate 'restartServer' $true
$restartCloudflared = Get-PropertyValue $afterUpdate 'restartCloudflared' $true

if ($restartServer -and -not $NoRestart) {
  Write-ProjectLog 'Restarting server after Git update.' 'logs\git-update.log'
  & "$PSScriptRoot\restart-server.ps1"
}

if ($restartCloudflared -and -not $NoRestart) {
  Write-ProjectLog 'Restarting cloudflared after Git update.' 'logs\git-update.log'
  try {
    & "$PSScriptRoot\restart-cloudflared.ps1"
  } catch {
    Write-ProjectLog "cloudflared restart skipped or failed: $($_.Exception.Message)" 'logs\git-update.log'
    Write-Warning "cloudflared restart skipped or failed: $($_.Exception.Message)"
  }
}
