[CmdletBinding()]
param(
  [switch] $Background
)

. "$PSScriptRoot\lib.ps1"

$root = Get-ProjectRoot
$config = Get-SiteConfig
$hostName = Get-PropertyValue $config.server 'host' '127.0.0.1'
$port = Get-PropertyValue $config.server 'port' 8787
$gitConfig = Get-PropertyValue $config 'git' $null
$webConfig = Get-PropertyValue $gitConfig 'web' $null
$pullOnStart = Get-PropertyValue $webConfig 'pullOnStart' $false
$node = Get-RequiredCommand 'node'
$logsDir = Join-Path $root 'logs'
Ensure-Directory $logsDir

$existing = Get-ServerProcess
if ($null -ne $existing) {
  Write-Host "Server is already running. PID: $($existing.ProcessId), URL: http://${hostName}:${port}"
  exit 0
}

if ($pullOnStart) {
  & "$PSScriptRoot\sync-web-repo.ps1" -Quiet
}

if ($Background) {
  $outLog = Join-Path $logsDir 'server.out.log'
  $errLog = Join-Path $logsDir 'server.err.log'

  Start-Process `
    -FilePath $node.Source `
    -ArgumentList @('src\server.js') `
    -WorkingDirectory $root `
    -WindowStyle Hidden `
    -RedirectStandardOutput $outLog `
    -RedirectStandardError $errLog

  Start-Sleep -Milliseconds 800
  $started = Get-ServerProcess
  if ($null -eq $started) {
    throw "Server did not start. Check $errLog"
  }

  Write-Host "Server started. PID: $($started.ProcessId), URL: http://${hostName}:${port}"
  exit 0
}

Set-Location $root
& $node.Source 'src\server.js'
