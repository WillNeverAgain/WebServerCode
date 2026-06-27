[CmdletBinding()]
param(
  [switch] $Quiet,
  [switch] $ShowProgress,
  [int] $StallTimeoutSeconds = 120,
  [int] $MaxRetries = 2
)

. "$PSScriptRoot\lib.ps1"

$config = Get-SiteConfig
$gitConfig = Get-PropertyValue $config 'git' $null
$webConfig = Get-PropertyValue $gitConfig 'web' $null
$result = Update-GitRepository `
  -Name 'web' `
  -RepositoryConfig $webConfig `
  -DefaultLocalPath 'webapps\current' `
  -LogFile 'logs\web-repo-sync.log' `
  -ShowProgress:$ShowProgress `
  -StallTimeoutSeconds $StallTimeoutSeconds `
  -MaxRetries $MaxRetries

if (-not $Quiet) {
  $status = if ($result.Changed) { 'changed' } elseif ($result.Skipped) { 'skipped' } else { 'unchanged' }
  Write-Host "web: $status ($($result.Message))"
}
