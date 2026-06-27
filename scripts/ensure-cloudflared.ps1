[CmdletBinding()]
param(
  [switch] $NoInstall,
  [switch] $NoLogin,
  [switch] $NoCreateTunnel,
  [switch] $NoRouteDns
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

function Get-FirstJsonArrayFromText {
  param(
    [Parameter(Mandatory = $false)] [string] $Text
  )

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return ''
  }

  $start = $Text.IndexOf('[')
  $end = $Text.LastIndexOf(']')
  if ($start -lt 0 -or $end -le $start) {
    return ''
  }

  return $Text.Substring($start, $end - $start + 1)
}

function Get-TunnelsByName {
  param(
    [Parameter(Mandatory = $true)] [string] $TunnelName
  )

  try {
    $jsonOutput = Invoke-CloudflaredCapture @('tunnel', 'list', '--name', $TunnelName, '--output', 'json')
    $jsonArray = Get-FirstJsonArrayFromText $jsonOutput
    if ([string]::IsNullOrWhiteSpace($jsonArray)) {
      throw 'cloudflared tunnel list did not include a JSON array.'
    }

    $items = $jsonArray | ConvertFrom-Json
    return @($items | Where-Object {
      $_.name -eq $TunnelName -and ($_.deleted_at -eq $null -or $_.deleted_at -eq '0001-01-01T00:00:00Z')
    })
  } catch {
    Write-Warning "Unable to read tunnel list as JSON: $($_.Exception.Message)"
  }

  return @()
}

function Select-TunnelForName {
  param(
    [Parameter(Mandatory = $true)] [string] $TunnelName,
    [Parameter(Mandatory = $false)] [string] $PreferredTunnelId = ''
  )

  $matches = @(Get-TunnelsByName $TunnelName)
  if ($matches.Count -eq 0) {
    return $null
  }

  if (-not [string]::IsNullOrWhiteSpace($PreferredTunnelId)) {
    $preferred = @($matches | Where-Object { ([string] $_.id).ToLowerInvariant() -eq $PreferredTunnelId.ToLowerInvariant() } | Select-Object -First 1)
    if ($preferred.Count -gt 0) {
      return $preferred[0]
    }
  }

  return @($matches | Sort-Object `
    @{ Expression = { @($_.connections).Count }; Descending = $true }, `
    @{ Expression = { $_.created_at }; Descending = $true } | Select-Object -First 1)[0]
}

function Get-TunnelIdFromCreateOutput {
  param(
    [Parameter(Mandatory = $true)] [string] $TunnelName
  )

  try {
    $createOutput = Invoke-CloudflaredCapture @('tunnel', 'create', $TunnelName)
    return Get-FirstUuidFromText $createOutput
  } catch {
    Write-Warning "Tunnel create failed for '$TunnelName': $($_.Exception.Message)"
  }

  return ''
}

function Test-TunnelInfoAccessible {
  param(
    [Parameter(Mandatory = $true)] [string] $TunnelId
  )

  try {
    [void] (Invoke-CloudflaredCapture `
      -Arguments @('tunnel', 'info', $TunnelId) `
      -TimeoutSeconds 45 `
      -AllowNonZero `
      -SuppressNonZeroWarning)
    return $script:LastCloudflaredExitCode -eq 0
  } catch {
    Write-Warning "Unable to read tunnel info for ${TunnelId}: $($_.Exception.Message)"
    return $false
  }
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
  $state = Get-CloudflaredState $Config
  $tunnelId = Get-PropertyValue $state 'tunnelId' ''
  $statePath = Get-CloudflaredStatePath $Config

  if (Test-IsPlaceholder $tunnelName) {
    Write-Warning 'cloudflared.tunnelName is missing or still a placeholder.'
    return $false
  }

  $selectedTunnel = Select-TunnelForName -TunnelName $tunnelName -PreferredTunnelId $tunnelId
  if ($null -eq $selectedTunnel) {
    $autoCreate = Get-PropertyValue $CloudflaredConfig 'autoCreateTunnel' $true
    if ($NoCreateTunnel -or -not $autoCreate) {
      Write-Warning "Cloudflare tunnel named '$tunnelName' does not exist, and automatic tunnel creation is disabled."
      return $false
    }

    Write-Host "Creating Cloudflare tunnel: $tunnelName"
    $createdId = Get-TunnelIdFromCreateOutput $tunnelName
    if ([string]::IsNullOrWhiteSpace($createdId)) {
      $selectedTunnel = Select-TunnelForName -TunnelName $tunnelName
    } else {
      $selectedTunnel = [pscustomobject]@{
        id = $createdId
        name = $tunnelName
        connections = @()
      }
    }
  } else {
    Write-Host "Found Cloudflare tunnel '$tunnelName': $($selectedTunnel.id)"
  }

  if ($null -eq $selectedTunnel -or [string]::IsNullOrWhiteSpace([string] $selectedTunnel.id)) {
    Write-Warning "Unable to create or find tunnel '$tunnelName'."
    return $false
  }

  $targetTunnelId = ([string] $selectedTunnel.id).ToLowerInvariant()
  if (-not (Test-TunnelInfoAccessible $targetTunnelId)) {
    Write-Warning "Tunnel '$tunnelName' exists but tunnel info is not accessible: $targetTunnelId"
    return $false
  }

  if (-not [string]::IsNullOrWhiteSpace($tunnelId) -and $tunnelId.ToLowerInvariant() -ne $targetTunnelId) {
    Write-Warning "Local state tunnelId '$tunnelId' does not match tunnelName '$tunnelName'. Updating local state to '$targetTunnelId'."
  }

  $newCredentialsPath = Get-CloudflaredCredentialsPath $targetTunnelId
  $newCredentialsFile = "%USERPROFILE%\.cloudflared\$targetTunnelId.json"

  if (-not (Test-Path -LiteralPath $newCredentialsPath)) {
    Write-Warning "Tunnel credentials file does not exist yet: $newCredentialsPath"
    return $false
  }

  $stateChanged = $false
  $currentCredentialsFile = Get-PropertyValue $state 'credentialsFile' ''
  if ($tunnelId.ToLowerInvariant() -ne $targetTunnelId -or $currentCredentialsFile -ne $newCredentialsFile -or -not (Test-Path -LiteralPath $statePath)) {
    $stateChanged = $true
  }

  if ($stateChanged) {
    $savedPath = Save-CloudflaredState `
      -Config $Config `
      -TunnelId $targetTunnelId `
      -CredentialsFile $newCredentialsFile `
      -Reason "validated tunnelName '$tunnelName'"
    Write-Host "Updated local cloudflared state: $savedPath"
  } else {
    Write-Host "Local tunnel state is valid: $tunnelName -> $targetTunnelId"
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

  $state = Get-CloudflaredState $Config
  $tunnelId = Get-PropertyValue $state 'tunnelId' ''
  if (Test-IsPlaceholder $tunnelId) {
    Write-Warning 'DNS route skipped because local cloudflared state tunnelId is not configured.'
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
