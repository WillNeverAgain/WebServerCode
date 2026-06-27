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
  return
}

$cloudflaredCommand = Get-RequiredCommand 'cloudflared'
& "$PSScriptRoot\cloudflared-write-config.ps1"

$existing = Get-CloudflaredProcess
if ($null -ne $existing) {
  Write-Host "cloudflared is already running. PID: $($existing.ProcessId)"
  return
}

$configFile = Resolve-ProjectPath (Get-PropertyValue $cloudflared 'configFile' 'config\cloudflared.generated.yml')
$protocol = Get-PropertyValue $cloudflared 'protocol' ''
$edgeIpVersion = Get-PropertyValue $cloudflared 'edgeIpVersion' ''
$proxyUrl = Get-PropertyValue $cloudflared 'proxyUrl' ''
$tunnelName = Get-PropertyValue $cloudflared 'tunnelName' 'local-html-server'
$tunnelId = Get-PropertyValue $cloudflared 'tunnelId' ''
$tunnel = $tunnelName
if ($tunnelId -ne '') {
  $tunnel = $tunnelId
}

$cloudflaredArgs = @('tunnel')
if (-not [string]::IsNullOrWhiteSpace($protocol)) {
  $cloudflaredArgs += @('--protocol', $protocol)
}
if (-not [string]::IsNullOrWhiteSpace($edgeIpVersion)) {
  $cloudflaredArgs += @('--edge-ip-version', $edgeIpVersion)
}
$cloudflaredArgs += @('--config', $configFile, 'run', $tunnel)

$logsDir = Join-Path (Get-ProjectRoot) 'logs'
Ensure-Directory $logsDir

$previousProxyEnv = @{
  HTTP_PROXY = $env:HTTP_PROXY
  HTTPS_PROXY = $env:HTTPS_PROXY
  ALL_PROXY = $env:ALL_PROXY
  NO_PROXY = $env:NO_PROXY
  TUNNEL_TRANSPORT_PROTOCOL = $env:TUNNEL_TRANSPORT_PROTOCOL
}

function Restore-ProxyEnvironment {
  foreach ($name in $previousProxyEnv.Keys) {
    if ($null -eq $previousProxyEnv[$name]) {
      Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    } else {
      Set-Item -Path "Env:$name" -Value $previousProxyEnv[$name]
    }
  }
}

if (-not [string]::IsNullOrWhiteSpace($protocol)) {
  $env:TUNNEL_TRANSPORT_PROTOCOL = $protocol
}

if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) {
  $env:HTTP_PROXY = $proxyUrl
  $env:HTTPS_PROXY = $proxyUrl
  $env:ALL_PROXY = $proxyUrl
  $env:NO_PROXY = '127.0.0.1,localhost,::1'
}

try {
  if ($Background) {
    $outLog = Join-Path $logsDir 'cloudflared.out.log'
    $errLog = Join-Path $logsDir 'cloudflared.err.log'
    $process = Start-Process `
      -FilePath $cloudflaredCommand.Source `
      -ArgumentList $cloudflaredArgs `
      -WorkingDirectory (Get-ProjectRoot) `
      -WindowStyle Hidden `
      -RedirectStandardOutput $outLog `
      -RedirectStandardError $errLog `
      -PassThru
    Set-Content -LiteralPath (Get-CloudflaredPidFile) -Value $process.Id -Encoding ASCII
    Write-Host "cloudflared started in background. PID: $($process.Id). Logs: $outLog, $errLog"
    return
  }

  & $cloudflaredCommand.Source @cloudflaredArgs
} finally {
  Restore-ProxyEnvironment
}
