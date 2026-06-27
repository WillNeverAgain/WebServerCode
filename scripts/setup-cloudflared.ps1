[CmdletBinding()]
param(
  [switch] $Login,
  [switch] $CreateTunnel,
  [switch] $RouteDns
)

. "$PSScriptRoot\lib.ps1"

$cloudflaredCommand = Get-RequiredCommand 'cloudflared'
$config = Get-SiteConfig
$cloudflared = Get-PropertyValue $config 'cloudflared' $null
$domain = Get-PropertyValue $config.site 'domain' ''
$tunnelName = Get-PropertyValue $cloudflared 'tunnelName' 'local-html-server'
$tunnelId = Get-PropertyValue $cloudflared 'tunnelId' ''
$tunnelForDns = $tunnelName
if ($tunnelId -ne '') {
  $tunnelForDns = $tunnelId
}

if ($Login) {
  Write-Host 'Opening cloudflared login flow...'
  & $cloudflaredCommand.Source tunnel login
  if ($LASTEXITCODE -ne 0) {
    throw 'cloudflared tunnel login failed.'
  }
}

if ($CreateTunnel) {
  Write-Host "Creating tunnel: $tunnelName"
  & $cloudflaredCommand.Source tunnel create $tunnelName
  if ($LASTEXITCODE -ne 0) {
    throw 'cloudflared tunnel create failed.'
  }

  Write-Host ''
  Write-Host 'Copy the generated tunnel UUID into config/site.config.json:'
  Write-Host '  cloudflared.tunnelId'
  Write-Host 'Then set cloudflared.credentialsFile to:'
  Write-Host '  %USERPROFILE%\.cloudflared\<Tunnel-UUID>.json'
}

& "$PSScriptRoot\cloudflared-write-config.ps1"

if ($RouteDns) {
  if ($domain -eq '' -or $domain -eq 'html.example.com') {
    throw 'Set site.domain in config/site.config.json before routing DNS.'
  }

  Write-Host "Routing DNS: $domain -> $tunnelForDns"
  & $cloudflaredCommand.Source tunnel route dns $tunnelForDns $domain
  if ($LASTEXITCODE -ne 0) {
    throw 'cloudflared tunnel route dns failed.'
  }
}

Write-Host 'cloudflared setup step finished.'
