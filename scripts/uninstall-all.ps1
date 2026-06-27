[CmdletBinding()]
param(
  [switch] $RemoveGeneratedFiles,
  [switch] $RemoveLogs,
  [switch] $RemoveWebRepo,
  [switch] $Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\lib.ps1"

$script:Warnings = New-Object System.Collections.Generic.List[string]
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

function Add-Action {
  param([Parameter(Mandatory = $true)] [string] $Message)
  $script:Actions.Add($Message) | Out-Null
  Write-Host "[OK] $Message"
}

function Remove-PathIfExists {
  param(
    [Parameter(Mandatory = $true)] [string] $PathValue,
    [switch] $Recurse
  )

  if (-not (Test-Path -LiteralPath $PathValue)) {
    return
  }

  if ($Recurse) {
    Remove-Item -LiteralPath $PathValue -Recurse -Force
  } else {
    Remove-Item -LiteralPath $PathValue -Force
  }
  Add-Action "Removed: $PathValue"
}

Write-Host "Windows Dual-Git HTML Server one-click uninstall"
Write-Host "Project: $(Get-ProjectRoot)"

try {
  $config = $null
  try {
    $config = Get-SiteConfig
    Add-Action "Config loaded: $(Get-ConfigPath)"
  } catch {
    Add-Warning "Config could not be loaded: $($_.Exception.Message)"
  }

  Write-Step 'Stop runtime processes'
  try {
    & "$PSScriptRoot\stop-cloudflared.ps1"
    Add-Action 'cloudflared stopped or was not running.'
  } catch {
    Add-Warning "Failed to stop cloudflared cleanly: $($_.Exception.Message)"
  }

  try {
    & "$PSScriptRoot\stop-server.ps1"
    Add-Action 'Local server stopped or was not running.'
  } catch {
    Add-Warning "Failed to stop local server cleanly: $($_.Exception.Message)"
  }

  Write-Step 'Remove scheduled tasks'
  try {
    & "$PSScriptRoot\uninstall-scheduled-tasks.ps1"
    Add-Action 'Scheduled tasks removed if they existed.'
  } catch {
    Add-Warning "Failed to remove scheduled tasks through uninstall script: $($_.Exception.Message)"
    if ($null -ne $config) {
      foreach ($taskName in (Get-ConfiguredTaskNames $config)) {
        try {
          if (Get-TaskExists $taskName) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Add-Action "Removed scheduled task: $taskName"
          }
        } catch {
          Add-Warning "Failed to remove scheduled task ${taskName}: $($_.Exception.Message)"
        }
      }
    }
  }

  Write-Step 'Remove generated files'
  if ($RemoveGeneratedFiles -or $Force) {
    Remove-PathIfExists (Resolve-ProjectPath 'config\cloudflared.generated.yml')
    Remove-PathIfExists (Resolve-ProjectPath 'logs\server.pid')
    Remove-PathIfExists (Resolve-ProjectPath 'logs\cloudflared.pid')
  } else {
    Add-Warning 'Generated files kept. Use -RemoveGeneratedFiles to remove generated config and pid files.'
  }

  if ($RemoveWebRepo -or $Force) {
    $webRepoPath = Resolve-ProjectPath 'webapps'
    Remove-PathIfExists $webRepoPath -Recurse
  } else {
    Add-Warning 'Web repository clone kept. Use -RemoveWebRepo to remove webapps\.'
  }

  if ($RemoveLogs -or $Force) {
    $logsPath = Resolve-ProjectPath 'logs'
    if (Test-Path -LiteralPath $logsPath) {
      Get-ChildItem -LiteralPath $logsPath -Force | Where-Object { $_.Name -ne '.gitkeep' } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
      }
      Add-Action "Removed log files under: $logsPath"
    }
  } else {
    Add-Warning 'Logs kept. Use -RemoveLogs to remove runtime logs.'
  }

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

  Write-Host ""
  Write-Host "Uninstall finished. Repository files and config were kept unless removal switches were used."
  exit 0
} catch {
  Write-Host ""
  Write-Host "Uninstall failed: $($_.Exception.Message)"
  exit 1
}
