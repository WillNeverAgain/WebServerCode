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
$state = Get-CloudflaredState $config
$tunnelId = Get-PropertyValue $state 'tunnelId' ''
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
  $output = Invoke-CloudflaredCapture @('tunnel', 'create', $tunnelName)
  $createdId = Get-FirstUuidFromText $output
  if ([string]::IsNullOrWhiteSpace($createdId)) {
    throw 'cloudflared tunnel create did not return a tunnel UUID.'
  }

  $credentialsFile = "%USERPROFILE%\.cloudflared\$createdId.json"
  [void] (Save-CloudflaredState `
    -Config $config `
    -TunnelId $createdId `
    -CredentialsFile $credentialsFile `
    -Reason "manual setup-cloudflared CreateTunnel for '$tunnelName'")
  Write-Host "Saved tunnel state: $(Get-CloudflaredStatePath $config)"
  $tunnelForDns = $createdId
}

$config = Get-SiteConfig
$cloudflared = Get-PropertyValue $config 'cloudflared' $null
$state = Get-CloudflaredState $config
$tunnelId = Get-PropertyValue $state 'tunnelId' ''
if ($tunnelId -ne '') {
  $tunnelForDns = $tunnelId
}

& "$PSScriptRoot\cloudflared-write-config.ps1"

if ($RouteDns) {
  if ($domain -eq '' -or $domain -eq 'html.example.com') {
    throw 'Set site.domain in config/site.config.json before routing DNS.'
  }

  Write-Host "Routing DNS: $domain -> $tunnelForDns"
  $routeArgs = @('tunnel', 'route', 'dns')
  if (Get-PropertyValue $cloudflared 'overwriteDns' $false) {
    $routeArgs += '--overwrite-dns'
  }
  $routeArgs += @($tunnelForDns, $domain)
  & $cloudflaredCommand.Source @routeArgs
  if ($LASTEXITCODE -ne 0) {
    throw 'cloudflared tunnel route dns failed.'
  }
}

Write-Host 'cloudflared setup step finished.'
