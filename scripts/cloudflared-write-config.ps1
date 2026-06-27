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
$tunnelId = Get-PropertyValue $cloudflared 'tunnelId' ''
$tunnel = $tunnelName
if ($tunnelId -ne '') {
  $tunnel = $tunnelId
}

$serverHost = Get-PropertyValue $config.server 'host' '127.0.0.1'
$serverPort = Get-PropertyValue $config.server 'port' 8787
$serviceUrl = Get-PropertyValue $cloudflared 'serviceUrl' "http://$($serverHost):$($serverPort)"
$credentialsFile = Get-PropertyValue $cloudflared 'credentialsFile' ''
$configFile = Get-PropertyValue $cloudflared 'configFile' 'config\cloudflared.generated.yml'
$logFile = Get-PropertyValue $cloudflared 'logFile' 'logs\cloudflared.log'

if ($credentialsFile -eq '' -or $credentialsFile -like '*<Tunnel-UUID>*') {
  Write-Warning 'cloudflared.credentialsFile still looks like a placeholder. Run setup-cloudflared.ps1 -CreateTunnel and update config/site.config.json with the generated UUID.'
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

Set-Content -LiteralPath $configPath -Value $content -Encoding UTF8
Write-Host "Wrote cloudflared config: $configPath"
