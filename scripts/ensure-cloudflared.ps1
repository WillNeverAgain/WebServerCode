[CmdletBinding()]
param(
  [switch] $NoInstall,
  [switch] $NoLogin,
  [switch] $NoCreateTunnel,
  [switch] $NoRouteDns
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

function Set-JsonProperty {
  param(
    [Parameter(Mandatory = $true)] $Object,
    [Parameter(Mandatory = $true)] [string] $Name,
    [Parameter(Mandatory = $true)] $Value
  )

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
  } else {
    $property.Value = $Value
  }
}

function Get-TunnelIdByName {
  param(
    [Parameter(Mandatory = $true)] [string] $TunnelName
  )

  try {
    $jsonOutput = Invoke-CloudflaredCapture @('tunnel', 'list', '--name', $TunnelName, '--output', 'json')
    $items = $jsonOutput | ConvertFrom-Json
    $match = @($items | Where-Object { $_.name -eq $TunnelName } | Select-Object -First 1)
    if ($match.Count -gt 0 -and $match[0].id) {
      return [string] $match[0].id
    }
  } catch {
    Write-Warning "Unable to read tunnel list as JSON: $($_.Exception.Message)"
  }

  try {
    $listOutput = Invoke-CloudflaredCapture @('tunnel', 'list', '--name', $TunnelName)
    return Get-FirstUuidFromText $listOutput
  } catch {
    Write-Warning "Unable to read tunnel list: $($_.Exception.Message)"
  }

  return ''
}

function Ensure-CloudflaredInstalled {
  param([Parameter(Mandatory = $true)] $CloudflaredConfig)

  if (Test-CommandExists 'cloudflared') {
    $command = Get-RequiredCommand 'cloudflared'
    Write-Host "cloudflared found: $($command.Source)"
    return $true
  }

  $autoInstall = Get-PropertyValue $CloudflaredConfig 'autoInstall' $true
  if ($NoInstall -or -not $autoInstall) {
    Write-Warning 'cloudflared is not installed and automatic installation is disabled.'
    return $false
  }

  Write-Host 'cloudflared is missing. Installing through winget...'
  & "$PSScriptRoot\install-cloudflared.ps1" -UseWinget

  if (Test-CommandExists 'cloudflared') {
    $command = Get-RequiredCommand 'cloudflared'
    Write-Host "cloudflared installed/found: $($command.Source)"
    return $true
  }

  Write-Warning 'cloudflared installation finished, but cloudflared.exe still was not found.'
  return $false
}

function Ensure-CloudflareLogin {
  param([Parameter(Mandatory = $true)] $CloudflaredConfig)

  $certPath = Get-CloudflaredCertPath
  if (Test-Path -LiteralPath $certPath) {
    Write-Host "Cloudflare login certificate found: $certPath"
    return $true
  }

  $autoLogin = Get-PropertyValue $CloudflaredConfig 'autoLogin' $true
  if ($NoLogin -or -not $autoLogin) {
    Write-Warning "Cloudflare login certificate is missing: $certPath"
    return $false
  }

  Write-Host 'Cloudflare login is required. A browser window will open; choose the Cloudflare zone for this site.'
  Write-Host 'Waiting for browser authorization to finish. If the browser does not open, copy the cloudflared URL printed below.'

  try {
    Invoke-CloudflaredCapture -Arguments @('tunnel', 'login') -TimeoutSeconds 900 -AllowNonZero | Out-Null
  } catch {
    Write-Warning "Cloudflare login command ended with an error: $($_.Exception.Message)"
  }

  if (Test-Path -LiteralPath $certPath) {
    Write-Host "Cloudflare login completed: $certPath"
    return $true
  }

  Write-Warning "Cloudflare login did not create certificate: $certPath"
  return $false
}

function Ensure-TunnelConfig {
  param(
    [Parameter(Mandatory = $true)] $Config,
    [Parameter(Mandatory = $true)] $CloudflaredConfig
  )

  $tunnelName = Get-PropertyValue $CloudflaredConfig 'tunnelName' 'local-html-server'
  $tunnelId = Get-PropertyValue $CloudflaredConfig 'tunnelId' ''
  $credentialsFile = Get-PropertyValue $CloudflaredConfig 'credentialsFile' ''
  $credentialsPath = [Environment]::ExpandEnvironmentVariables($credentialsFile)

  if (-not (Test-IsPlaceholder $tunnelId) -and -not (Test-IsPlaceholder $credentialsFile) -and (Test-Path -LiteralPath $credentialsPath)) {
    Write-Host "Tunnel is already configured: $tunnelId"
    return $true
  }

  $autoCreate = Get-PropertyValue $CloudflaredConfig 'autoCreateTunnel' $true
  if ($NoCreateTunnel -or -not $autoCreate) {
    Write-Warning 'Tunnel ID or credentials are missing, and automatic tunnel creation is disabled.'
    return $false
  }

  $existingId = Get-TunnelIdByName $tunnelName
  if ([string]::IsNullOrWhiteSpace($existingId)) {
    Write-Host "Creating Cloudflare tunnel: $tunnelName"
    try {
      $createOutput = Invoke-CloudflaredCapture @('tunnel', 'create', $tunnelName)
      $existingId = Get-FirstUuidFromText $createOutput
    } catch {
      Write-Warning "Tunnel create failed. Trying to find an existing tunnel named '$tunnelName'. $($_.Exception.Message)"
      $existingId = Get-TunnelIdByName $tunnelName
    }
  } else {
    Write-Host "Found existing Cloudflare tunnel '$tunnelName': $existingId"
  }

  if ([string]::IsNullOrWhiteSpace($existingId)) {
    Write-Warning "Unable to create or find tunnel '$tunnelName'."
    return $false
  }

  $newCredentialsPath = Get-CloudflaredCredentialsPath $existingId
  Set-JsonProperty $CloudflaredConfig 'tunnelId' $existingId
  Set-JsonProperty $CloudflaredConfig 'credentialsFile' "%USERPROFILE%\.cloudflared\$existingId.json"
  Save-SiteConfig $Config
  Write-Host "Updated config/site.config.json with tunnelId: $existingId"

  if (-not (Test-Path -LiteralPath $newCredentialsPath)) {
    Write-Warning "Tunnel credentials file does not exist yet: $newCredentialsPath"
    return $false
  }

  return $true
}

function Ensure-TunnelDnsRoute {
  param(
    [Parameter(Mandatory = $true)] $Config,
    [Parameter(Mandatory = $true)] $CloudflaredConfig
  )

  $domain = Get-PropertyValue $Config.site 'domain' ''
  if (Test-IsPlaceholder $domain) {
    Write-Warning "DNS route skipped because site.domain is not a real hostname: $domain"
    return $false
  }

  $autoRouteDns = Get-PropertyValue $CloudflaredConfig 'autoRouteDns' $true
  if ($NoRouteDns -or -not $autoRouteDns) {
    Write-Host 'DNS route step skipped by configuration.'
    return $true
  }

  $tunnelId = Get-PropertyValue $CloudflaredConfig 'tunnelId' ''
  if (Test-IsPlaceholder $tunnelId) {
    Write-Warning 'DNS route skipped because tunnelId is not configured.'
    return $false
  }

  try {
    $overwriteDns = Get-PropertyValue $CloudflaredConfig 'overwriteDns' $false
    $routeArgs = @('tunnel', 'route', 'dns')
    if ($overwriteDns) {
      $routeArgs += '--overwrite-dns'
    }
    $routeArgs += @($tunnelId, $domain)

    $routeOutput = Invoke-CloudflaredCapture `
      -Arguments $routeArgs `
      -AllowNonZero `
      -SuppressNonZeroWarning

    if ($script:LastCloudflaredExitCode -eq 0) {
      Write-Host "DNS route ensured: $domain -> $tunnelId"
      return $true
    }

    if ($routeOutput -match 'code:\s*1003' -or $routeOutput -match 'already exists') {
      Write-Host "DNS route already exists for $domain. Keeping the existing DNS record."
      return $true
    }

    Write-Warning "DNS route command failed. Details: cloudflared exited with code $script:LastCloudflaredExitCode."
    return $true
  } catch {
    Write-Warning "DNS route command failed. If the DNS record already exists, this may be harmless. Details: $($_.Exception.Message)"
    return $true
  }
}

$config = Get-SiteConfig
$cloudflared = Get-PropertyValue $config 'cloudflared' $null
if ($null -eq $cloudflared) {
  throw 'cloudflared section is missing in config/site.config.json.'
}

$enabled = Get-PropertyValue $cloudflared 'enabled' $true
if (-not $enabled) {
  Write-Host 'cloudflared is disabled in config/site.config.json.'
  return
}

$autoSetup = Get-PropertyValue $cloudflared 'autoSetup' $true
if (-not $autoSetup) {
  Write-Host 'cloudflared autoSetup is disabled in config/site.config.json.'
  return
}

if (-not (Ensure-CloudflaredInstalled $cloudflared)) {
  throw 'cloudflared installation check failed.'
}

if (-not (Ensure-CloudflareLogin $cloudflared)) {
  throw 'Cloudflare login is not ready.'
}

if (-not (Ensure-TunnelConfig $config $cloudflared)) {
  throw 'Cloudflare tunnel configuration is not ready.'
}

$config = Get-SiteConfig
$cloudflared = Get-PropertyValue $config 'cloudflared' $null
& "$PSScriptRoot\cloudflared-write-config.ps1"
[void] (Ensure-TunnelDnsRoute $config $cloudflared)

Write-Host 'cloudflared installation and tunnel setup are ready.'
