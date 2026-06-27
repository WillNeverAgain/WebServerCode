[CmdletBinding()]
param(
  [switch] $Background
)

. "$PSScriptRoot\lib.ps1"

$config = Get-SiteConfig
$cloudflared = Get-PropertyValue $config 'cloudflared' $null
$enabled = Get-PropertyValue $cloudflared 'enabled' $true
if (-not $enabled) {
  Write-Host 'cloudflared is disabled in config/site.config.json.'
  exit 0
}

$cloudflaredCommand = Get-RequiredCommand 'cloudflared'
& "$PSScriptRoot\cloudflared-write-config.ps1"

$existing = Get-CloudflaredProcess
if ($null -ne $existing) {
  Write-Host "cloudflared is already running. PID: $($existing.ProcessId)"
  exit 0
}

$configFile = Resolve-ProjectPath (Get-PropertyValue $cloudflared 'configFile' 'config\cloudflared.generated.yml')
$tunnelName = Get-PropertyValue $cloudflared 'tunnelName' 'local-html-server'
$tunnelId = Get-PropertyValue $cloudflared 'tunnelId' ''
$tunnel = $tunnelName
if ($tunnelId -ne '') {
  $tunnel = $tunnelId
}

$logsDir = Join-Path (Get-ProjectRoot) 'logs'
Ensure-Directory $logsDir

if ($Background) {
  $outLog = Join-Path $logsDir 'cloudflared.out.log'
  $errLog = Join-Path $logsDir 'cloudflared.err.log'
  $process = Start-Process `
    -FilePath $cloudflaredCommand.Source `
    -ArgumentList @('tunnel', '--config', $configFile, 'run', $tunnel) `
    -WorkingDirectory (Get-ProjectRoot) `
    -WindowStyle Hidden `
    -RedirectStandardOutput $outLog `
    -RedirectStandardError $errLog `
    -PassThru
  Set-Content -LiteralPath (Get-CloudflaredPidFile) -Value $process.Id -Encoding ASCII
  Write-Host "cloudflared started in background. PID: $($process.Id). Logs: $outLog, $errLog"
  exit 0
}

& $cloudflaredCommand.Source tunnel --config $configFile run $tunnel
