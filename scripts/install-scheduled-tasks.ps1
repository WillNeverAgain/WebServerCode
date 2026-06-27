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
$script:TaskInstallFailures = New-Object System.Collections.Generic.List[string]

function Register-ManagedScheduledTask {
  param(
    [Parameter(Mandatory = $true)] [string] $TaskName,
    [Parameter(Mandatory = $true)] $Action,
    [Parameter(Mandatory = $true)] $Trigger,
    [Parameter(Mandatory = $true)] [string] $Description,
    [Parameter(Mandatory = $true)] [string] $SuccessMessage
  )

  try {
    Register-ScheduledTask `
      -TaskName $TaskName `
      -Action $Action `
      -Trigger $Trigger `
      -Settings $settings `
      -Description $Description `
      -Force `
      -ErrorAction Stop | Out-Null

    if (-not (Get-TaskExists $TaskName)) {
      throw 'Task was not found after registration.'
    }

    Write-Host $SuccessMessage
    return $true
  } catch {
    $message = "Failed to install scheduled task '$TaskName': $($_.Exception.Message)"
    Write-Warning $message
    $script:TaskInstallFailures.Add($message) | Out-Null
    return $false
  }
}

$serverAction = New-ScheduledTaskAction `
  -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$root\scripts\start-server.ps1`" -Background"
$serverTrigger = New-ScheduledTaskTrigger -AtLogOn
[void] (Register-ManagedScheduledTask `
  -TaskName "$serverName-Start" `
  -Action $serverAction `
  -Trigger $serverTrigger `
  -Description 'Start the local HTML server at user logon.' `
  -SuccessMessage "Installed scheduled task: $serverName-Start")

$pullAction = New-ScheduledTaskAction `
  -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$root\scripts\update-from-git.ps1`""
$pullTrigger = New-ScheduledTaskTrigger -Daily -At $dailyTime
[void] (Register-ManagedScheduledTask `
  -TaskName "$serverName-GitPull" `
  -Action $pullAction `
  -Trigger $pullTrigger `
  -Description 'Pull Git updates for the local HTML server once per day.' `
  -SuccessMessage "Installed scheduled task: $serverName-GitPull at $DailyAt")

if ($IncludeCloudflared) {
  $cloudflaredAction = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$root\scripts\start-cloudflared.ps1`" -Background"
  $cloudflaredTrigger = New-ScheduledTaskTrigger -AtLogOn
  [void] (Register-ManagedScheduledTask `
    -TaskName "$serverName-Cloudflared" `
    -Action $cloudflaredAction `
    -Trigger $cloudflaredTrigger `
    -Description 'Start cloudflared tunnel at user logon.' `
    -SuccessMessage "Installed scheduled task: $serverName-Cloudflared")
}

if ($script:TaskInstallFailures.Count -gt 0) {
  $details = $script:TaskInstallFailures -join "`n"
  throw "Scheduled task installation had failures:`n$details`nRun PowerShell as Administrator, or rerun start-all with -SkipScheduledTasks."
}
