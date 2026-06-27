[CmdletBinding()]
param(
  [switch] $SkipGitSync,
  [switch] $SkipScheduledTasks,
  [switch] $SkipCloudflared,
  [switch] $InstallCloudflared,
  [switch] $Strict,
  [int] $WebSyncStallTimeoutSeconds = 120,
  [int] $WebSyncRetries = 2
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Errors = New-Object System.Collections.Generic.List[string]
$script:Actions = New-Object System.Collections.Generic.List[string]

function Write-Step {
  param([Parameter(Mandatory = $true)] [string] $Message)
  Write-Host ""
  Write-Host "== $Message =="
}

function Add-Warning {
  param([Parameter(Mandatory = $true)] [string] $Message)
  $script:Warnings.Add($Message) | Out-Null
  Write-Warning $Message
}

function Add-ErrorMessage {
  param([Parameter(Mandatory = $true)] [string] $Message)
  $script:Errors.Add($Message) | Out-Null
  Write-Error $Message -ErrorAction Continue
}

function Add-Action {
  param([Parameter(Mandatory = $true)] [string] $Message)
  $script:Actions.Add($Message) | Out-Null
  Write-Host "[OK] $Message"
}

function Test-NodeVersion {
  if (-not (Test-CommandExists 'node')) {
    Add-ErrorMessage 'Node.js was not found. Install Node.js 18 or newer, then run start-all again.'
    return $false
  }

  $versionText = (& node --version).Trim()
  $versionNumber = $versionText.TrimStart('v')
  $major = 0
  if (-not [int]::TryParse(($versionNumber -split '\.')[0], [ref] $major)) {
    Add-Warning "Unable to parse Node.js version: $versionText"
    return $true
  }

  if ($major -lt 18) {
    Add-ErrorMessage "Node.js version is $versionText. This framework requires Node.js 18 or newer."
    return $false
  }

  Add-Action "Node.js detected: $versionText"
  return $true
}

function Test-GitAvailability {
  if (-not (Test-CommandExists 'git')) {
    Add-ErrorMessage 'Git was not found. Install Git for Windows before enabling repository sync.'
    return $false
  }

  $version = (& git --version)
  Add-Action $version
  return $true
}

function Test-ConfigShape {
  param([Parameter(Mandatory = $true)] $Config)

  $ok = $true
  $hostName = Get-PropertyValue $Config.server 'host' '127.0.0.1'
  $port = Get-PropertyValue $Config.server 'port' 8787
  $domain = Get-PropertyValue $Config.site 'domain' ''
  $gitConfig = Get-PropertyValue $Config 'git' $null
  $webConfig = Get-PropertyValue $gitConfig 'web' $null
  $webEntry = Get-PropertyValue $webConfig 'entry' 'server-entry.js'
  $webLocalPath = Resolve-ProjectPath (Get-PropertyValue $webConfig 'localPath' 'webapps\current')
  $fallback = Get-PropertyValue $webConfig 'fallbackToBundledExample' $true
  $bundledPath = Resolve-ProjectPath (Get-PropertyValue $webConfig 'bundledExamplePath' 'examples\web-repo')

  if (-not [int]::TryParse([string] $port, [ref] ([int] $null))) {
    Add-ErrorMessage "server.port must be a number. Current value: $port"
    $ok = $false
  }

  if (Test-IsPlaceholder $domain) {
    Add-Warning "site.domain is still a placeholder: '$domain'. Local server can run, but cloudflared DNS routing needs a real Cloudflare-managed hostname."
  } else {
    Add-Action "Configured public domain: $domain"
  }

  if (-not (Test-Path -LiteralPath (Join-Path $webLocalPath $webEntry))) {
    if ($fallback -and (Test-Path -LiteralPath (Join-Path $bundledPath $webEntry))) {
      Add-Warning "Web repository entry was not found at $webLocalPath\$webEntry. The bundled example will be used."
    } else {
      Add-ErrorMessage "Web entry not found: $webLocalPath\$webEntry. Configure git.web.url or set git.web.fallbackToBundledExample to true."
      $ok = $false
    }
  } else {
    Add-Action "Web entry found: $webLocalPath\$webEntry"
  }

  Add-Action "Local server target: http://${hostName}:${port}"
  return $ok
}

function Invoke-WebRepoSync {
  param([Parameter(Mandatory = $true)] $Config)

  if ($SkipGitSync) {
    Add-Warning 'Git sync skipped by -SkipGitSync.'
    return
  }

  $gitConfig = Get-PropertyValue $Config 'git' $null
  $webConfig = Get-PropertyValue $gitConfig 'web' $null
  $webUrl = Get-PropertyValue $webConfig 'url' ''

  if ([string]::IsNullOrWhiteSpace($webUrl)) {
    Add-Warning 'git.web.url is empty. Web repository sync skipped; bundled example or existing local web repo will be used.'
    return
  }

  try {
    & "$PSScriptRoot\sync-web-repo.ps1" `
      -ShowProgress `
      -StallTimeoutSeconds $WebSyncStallTimeoutSeconds `
      -MaxRetries $WebSyncRetries
    Add-Action 'Web repository sync finished.'
  } catch {
    Add-ErrorMessage "Web repository sync failed: $($_.Exception.Message)"
  }
}

function Install-AutomationTasks {
  param(
    [Parameter(Mandatory = $true)] $Config,
    [Parameter(Mandatory = $true)] [bool] $IncludeCloudflared
  )

  if ($SkipScheduledTasks) {
    Add-Warning 'Scheduled task installation skipped by -SkipScheduledTasks.'
    return
  }

  try {
    if ($IncludeCloudflared) {
      & "$PSScriptRoot\install-scheduled-tasks.ps1" -IncludeCloudflared
    } else {
      & "$PSScriptRoot\install-scheduled-tasks.ps1"
    }

    $taskNames = Get-ConfiguredTaskNames $Config
    foreach ($taskName in $taskNames) {
      if (Get-TaskExists $taskName) {
        Add-Action "Scheduled task installed: $taskName"
      }
    }
  } catch {
    Add-ErrorMessage "Failed to install scheduled tasks: $($_.Exception.Message)"
  }
}

function Start-LocalServer {
  param([Parameter(Mandatory = $true)] $Config)

  try {
    & "$PSScriptRoot\start-server.ps1" -Background
    Start-Sleep -Milliseconds 800
  } catch {
    Add-ErrorMessage "Failed to start local server: $($_.Exception.Message)"
    return
  }

  $hostName = Get-PropertyValue $Config.server 'host' '127.0.0.1'
  $port = Get-PropertyValue $Config.server 'port' 8787
  $healthUrl = "http://${hostName}:${port}/_health"

  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $healthUrl -TimeoutSec 8
    if ($response.StatusCode -eq 200) {
      Add-Action "Local server health check passed: $healthUrl"
    } else {
      Add-ErrorMessage "Local server health check returned HTTP $($response.StatusCode): $healthUrl"
    }
  } catch {
    Add-ErrorMessage "Local server health check failed: $($_.Exception.Message)"
  }
}

function Ensure-CloudflaredCommand {
  if (Test-CommandExists 'cloudflared') {
    $version = (& cloudflared --version)
    Add-Action "cloudflared detected: $version"
    return $true
  }

  if ($InstallCloudflared) {
    try {
      & "$PSScriptRoot\install-cloudflared.ps1" -UseWinget
      $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
      $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
      $env:Path = "$machinePath;$userPath"
    } catch {
      Add-Warning "Automatic cloudflared installation failed: $($_.Exception.Message)"
    }
  } else {
    Add-Warning 'cloudflared was not found. Automatic install was not requested.'
  }

  if (Test-CommandExists 'cloudflared') {
    $version = (& cloudflared --version)
    Add-Action "cloudflared detected after install: $version"
    return $true
  }

  Add-Warning 'cloudflared is unavailable. Run: .\scripts\install-cloudflared.ps1 -UseWinget'
  return $false
}

function Test-CloudflaredConfigReady {
  param([Parameter(Mandatory = $true)] $Config)

  $cloudflared = Get-PropertyValue $Config 'cloudflared' $null
  $enabled = Get-PropertyValue $cloudflared 'enabled' $true
  if (-not $enabled) {
    Add-Warning 'cloudflared is disabled in config/site.config.json.'
    return $false
  }

  $domain = Get-PropertyValue $Config.site 'domain' ''
  $tunnelId = Get-PropertyValue $cloudflared 'tunnelId' ''
  $credentialsFile = Get-PropertyValue $cloudflared 'credentialsFile' ''
  $credentialsPath = [Environment]::ExpandEnvironmentVariables($credentialsFile)

  $ready = $true
  if (Test-IsPlaceholder $domain) {
    Add-Warning "cloudflared is not ready: site.domain is not a real hostname. Current value: '$domain'"
    $ready = $false
  }

  if (Test-IsPlaceholder $tunnelId) {
    Add-Warning 'cloudflared is not ready: cloudflared.tunnelId is empty or still a placeholder.'
    $ready = $false
  }

  if (Test-IsPlaceholder $credentialsFile) {
    Add-Warning "cloudflared credentials file is missing or placeholder: $credentialsFile"
    $ready = $false
  } elseif (-not (Test-Path -LiteralPath $credentialsPath)) {
    Add-Warning "cloudflared credentials file does not exist: $credentialsPath"
    $ready = $false
  }

  if (-not $ready) {
    Write-Host ""
    Write-Host "Cloudflared setup commands:"
    Write-Host "  .\scripts\install-cloudflared.ps1 -UseWinget"
    Write-Host "  .\scripts\setup-cloudflared.ps1 -Login -CreateTunnel"
    Write-Host "  # Put the generated tunnel UUID into config\site.config.json"
    Write-Host "  .\scripts\setup-cloudflared.ps1 -RouteDns"
  }

  return $ready
}

function Start-CloudflaredTunnel {
  param([Parameter(Mandatory = $true)] $Config)

  if ($SkipCloudflared) {
    Add-Warning 'cloudflared start skipped by -SkipCloudflared.'
    return $false
  }

  if (-not (Test-CloudflaredConfigReady $Config)) {
    return $false
  }

  if (-not (Ensure-CloudflaredCommand)) {
    return $false
  }

  try {
    & "$PSScriptRoot\start-cloudflared.ps1" -Background
    Start-Sleep -Milliseconds 1000
    $process = Get-CloudflaredProcess
    if ($null -eq $process) {
      Add-ErrorMessage 'cloudflared did not remain running. Check logs\cloudflared.err.log and logs\cloudflared.out.log.'
      return $false
    }

    Add-Action "cloudflared is running. PID: $($process.ProcessId)"
    return $true
  } catch {
    Add-ErrorMessage "Failed to start cloudflared: $($_.Exception.Message)"
    return $false
  }
}

Write-Host "Windows Dual-Git HTML Server one-click startup"
Write-Host "Project: $(Get-ProjectRoot)"

try {
  Write-Step 'Load configuration'
  $config = Get-SiteConfig
  Add-Action "Config loaded: $(Get-ConfigPath)"

  Write-Step 'Preflight checks'
  $nodeOk = Test-NodeVersion
  $gitOk = Test-GitAvailability
  $configOk = Test-ConfigShape $config

  if ($Strict -and (-not $nodeOk -or -not $gitOk -or -not $configOk)) {
    throw 'Strict mode stopped startup because preflight checks failed.'
  }

  if (-not $nodeOk -or -not $configOk) {
    throw 'Startup stopped because required checks failed.'
  }

  Write-Step 'Sync web repository'
  if ($gitOk) {
    Invoke-WebRepoSync $config
  } else {
    Add-Warning 'Git is unavailable, repository sync skipped.'
  }

  Write-Step 'Start local server'
  Start-LocalServer $config

  Write-Step 'Start cloudflared'
  $cloudflaredStarted = Start-CloudflaredTunnel $config

  Write-Step 'Install automation tasks'
  Install-AutomationTasks $config $cloudflaredStarted

  Write-Step 'Summary'
  foreach ($action in $script:Actions) {
    Write-Host "[OK] $action"
  }

  if ($script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnings:"
    foreach ($warning in $script:Warnings) {
      Write-Host "  - $warning"
    }
  }

  if ($script:Errors.Count -gt 0) {
    Write-Host ""
    Write-Host "Errors:"
    foreach ($errorMessage in $script:Errors) {
      Write-Host "  - $errorMessage"
    }
    exit 1
  }

  Write-Host ""
  Write-Host "Startup finished."
  exit 0
} catch {
  Write-Host ""
  Write-Host "Startup failed: $($_.Exception.Message)"
  if ($script:Errors.Count -gt 0) {
    Write-Host "Errors:"
    foreach ($errorMessage in $script:Errors) {
      Write-Host "  - $errorMessage"
    }
  }
  Write-Host ""
  Write-Host "Useful logs:"
  Write-Host "  logs\server.err.log"
  Write-Host "  logs\server.out.log"
  Write-Host "  logs\cloudflared.err.log"
  Write-Host "  logs\git-update.log"
  exit 1
}
