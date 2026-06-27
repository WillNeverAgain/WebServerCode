[CmdletBinding()]
param(
  [string] $DailyAt = '',
  [switch] $IncludeCloudflared
)

. "$PSScriptRoot\lib.ps1"

$root = Get-ProjectRoot
$config = Get-SiteConfig
$serverName = Get-PropertyValue $config.server 'name' 'LocalHtmlServer'
$gitConfig = Get-PropertyValue $config 'git' $null

if ($DailyAt -eq '') {
  $DailyAt = Get-PropertyValue $gitConfig 'dailyTime' '03:20'
}

$dailyTime = [DateTime]::ParseExact($DailyAt, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

$serverAction = New-ScheduledTaskAction `
  -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$root\scripts\start-server.ps1`" -Background"
$serverTrigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask `
  -TaskName "$serverName-Start" `
  -Action $serverAction `
  -Trigger $serverTrigger `
  -Settings $settings `
  -Description 'Start the local HTML server at user logon.' `
  -Force | Out-Null
Write-Host "Installed scheduled task: $serverName-Start"

$pullAction = New-ScheduledTaskAction `
  -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$root\scripts\update-from-git.ps1`""
$pullTrigger = New-ScheduledTaskTrigger -Daily -At $dailyTime
Register-ScheduledTask `
  -TaskName "$serverName-GitPull" `
  -Action $pullAction `
  -Trigger $pullTrigger `
  -Settings $settings `
  -Description 'Pull Git updates for the local HTML server once per day.' `
  -Force | Out-Null
Write-Host "Installed scheduled task: $serverName-GitPull at $DailyAt"

if ($IncludeCloudflared) {
  $cloudflaredAction = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$root\scripts\start-cloudflared.ps1`" -Background"
  $cloudflaredTrigger = New-ScheduledTaskTrigger -AtLogOn
  Register-ScheduledTask `
    -TaskName "$serverName-Cloudflared" `
    -Action $cloudflaredAction `
    -Trigger $cloudflaredTrigger `
    -Settings $settings `
    -Description 'Start cloudflared tunnel at user logon.' `
    -Force | Out-Null
  Write-Host "Installed scheduled task: $serverName-Cloudflared"
}
