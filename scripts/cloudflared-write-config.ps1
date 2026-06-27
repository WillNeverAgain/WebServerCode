[CmdletBinding()]
param()

. "$PSScriptRoot\lib.ps1"

function ConvertTo-YamlSingleQuoted {
  param([Parameter(Mandatory = $true)] [string] $Value)
  return "'" + ($Value -replace "'", "''") + "'"
}

$config = Get-SiteConfig
$cloudflared = Get-PropertyValue $config 'cloudflared' $null
if ($null -eq $cloudflared) {
  throw 'cloudflared section is missing in config/site.config.json.'
}

$domain = Get-PropertyValue $config.site 'domain' ''
if ($domain -eq '') {
  throw 'site.domain must be configured before writing cloudflared config.'
}

$tunnelName = Get-PropertyValue $cloudflared 'tunnelName' 'local-html-server'
$state = Get-CloudflaredState $config
$tunnelId = Get-PropertyValue $state 'tunnelId' ''
$tunnel = $tunnelName
if ($tunnelId -ne '') {
  $tunnel = $tunnelId
}

$serverHost = Get-PropertyValue $config.server 'host' '127.0.0.1'
$serverPort = Get-PropertyValue $config.server 'port' 8787
$serviceUrl = Get-PropertyValue $cloudflared 'serviceUrl' "http://$($serverHost):$($serverPort)"
$credentialsFile = Get-PropertyValue $state 'credentialsFile' ''
$configFile = Get-PropertyValue $cloudflared 'configFile' 'config\cloudflared.generated.yml'
$logFile = Get-PropertyValue $cloudflared 'logFile' 'logs\cloudflared.log'
$protocol = Get-PropertyValue $cloudflared 'protocol' ''
$edgeIpVersion = Get-PropertyValue $cloudflared 'edgeIpVersion' ''

if ((Test-IsPlaceholder $tunnelId) -or (Test-IsPlaceholder $credentialsFile)) {
  throw 'cloudflared local state is missing tunnelId or credentialsFile. Run .\scripts\ensure-cloudflared.ps1 first.'
}

$configPath = Resolve-ProjectPath $configFile
$logPath = Resolve-ProjectPath $logFile
$credentialsPath = [Environment]::ExpandEnvironmentVariables($credentialsFile)

Ensure-Directory (Split-Path -Parent $configPath)
Ensure-Directory (Split-Path -Parent $logPath)

$content = @"
tunnel: $(ConvertTo-YamlSingleQuoted $tunnel)
credentials-file: $(ConvertTo-YamlSingleQuoted $credentialsPath)
logfile: $(ConvertTo-YamlSingleQuoted $logPath)
ingress:
  - hostname: $(ConvertTo-YamlSingleQuoted $domain)
    service: $(ConvertTo-YamlSingleQuoted $serviceUrl)
  - service: http_status:404
"@

if (-not [string]::IsNullOrWhiteSpace($edgeIpVersion)) {
  $content = "edge-ip-version: $(ConvertTo-YamlSingleQuoted $edgeIpVersion)`n$content"
}

if (-not [string]::IsNullOrWhiteSpace($protocol)) {
  $content = "protocol: $(ConvertTo-YamlSingleQuoted $protocol)`n$content"
}

Write-Utf8NoBomFile -PathValue $configPath -Content ($content + [Environment]::NewLine)
Write-Host "Wrote cloudflared config: $configPath"
