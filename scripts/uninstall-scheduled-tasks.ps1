[CmdletBinding()]
param()

. "$PSScriptRoot\lib.ps1"

$config = Get-SiteConfig
$serverName = Get-PropertyValue $config.server 'name' 'LocalHtmlServer'
$taskNames = @("$serverName-Start", "$serverName-GitPull", "$serverName-Cloudflared")

foreach ($taskName in $taskNames) {
  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($null -ne $task) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed scheduled task: $taskName"
  }
}
