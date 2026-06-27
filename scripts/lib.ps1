$ErrorActionPreference = 'Stop'

function Get-ProjectRoot {
  return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function Get-ConfigPath {
  $root = Get-ProjectRoot
  return Join-Path $root 'config\site.config.json'
}

function Get-SiteConfig {
  $configPath = Get-ConfigPath
  if (-not (Test-Path -LiteralPath $configPath)) {
    throw "Config file not found: $configPath"
  }

  return Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
}

function Save-SiteConfig {
  param(
    [Parameter(Mandatory = $true)] $Config
  )

  $configPath = Get-ConfigPath
  $json = $Config | ConvertTo-Json -Depth 20
  Write-Utf8NoBomFile -PathValue $configPath -Content ($json + [Environment]::NewLine)
}

function Write-Utf8NoBomFile {
  param(
    [Parameter(Mandatory = $true)] [string] $PathValue,
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Content
  )

  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($PathValue, $Content, $encoding)
}

function Get-PropertyValue {
  param(
    [Parameter(Mandatory = $false)] $Object,
    [Parameter(Mandatory = $true)] [string] $Name,
    [Parameter(Mandatory = $false)] $Default = $null
  )

  if ($null -eq $Object) {
    return $Default
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) {
    return $Default
  }

  if ($property.Value -is [string] -and $property.Value -eq '') {
    return $Default
  }

  return $property.Value
}

function Resolve-ProjectPath {
  param(
    [Parameter(Mandatory = $true)] [string] $PathValue
  )

  $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
  if ([System.IO.Path]::IsPathRooted($expanded)) {
    return $expanded
  }

  return Join-Path (Get-ProjectRoot) $expanded
}

function Ensure-Directory {
  param(
    [Parameter(Mandatory = $true)] [string] $PathValue
  )

  if (-not (Test-Path -LiteralPath $PathValue)) {
    New-Item -ItemType Directory -Path $PathValue | Out-Null
  }
}

function Write-ProjectLog {
  param(
    [Parameter(Mandatory = $true)] [string] $Message,
    [Parameter(Mandatory = $false)] [string] $LogFile = 'logs\operations.log'
  )

  $logPath = Resolve-ProjectPath $LogFile
  Ensure-Directory (Split-Path -Parent $logPath)
  $line = '[{0}] {1}' -f (Get-Date).ToString('s'), $Message
  Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Get-RequiredCommand {
  param(
    [Parameter(Mandatory = $true)] [string] $Name
  )

  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $command -and $Name -eq 'cloudflared') {
    $cloudflaredPath = Find-CloudflaredExecutable
    if ($null -ne $cloudflaredPath) {
      return [pscustomobject]@{
        Name = 'cloudflared'
        Source = $cloudflaredPath
        Path = $cloudflaredPath
      }
    }
  }

  if ($null -eq $command) {
    throw "Required command not found: $Name"
  }

  return $command
}

function Find-CloudflaredExecutable {
  $command = Get-Command cloudflared -ErrorAction SilentlyContinue
  if ($null -ne $command) {
    return $command.Source
  }

  $candidatePaths = @(
    (Join-Path ${env:ProgramFiles(x86)} 'cloudflared\cloudflared.exe'),
    (Join-Path $env:ProgramFiles 'cloudflared\cloudflared.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Cloudflare.cloudflared_Microsoft.Winget.Source_8wekyb3d8bbwe\cloudflared.exe')
  )

  foreach ($candidatePath in $candidatePaths) {
    if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and (Test-Path -LiteralPath $candidatePath)) {
      return $candidatePath
    }
  }

  return $null
}

function Add-ToProcessPath {
  param(
    [Parameter(Mandatory = $true)] [string] $DirectoryPath
  )

  if (-not (Test-Path -LiteralPath $DirectoryPath)) {
    return
  }

  $pathParts = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if (-not ($pathParts -contains $DirectoryPath)) {
    $env:Path = "$env:Path;$DirectoryPath"
  }
}

function Get-CloudflaredHome {
  return Join-Path $env:USERPROFILE '.cloudflared'
}

function Get-CloudflaredCertPath {
  return Join-Path (Get-CloudflaredHome) 'cert.pem'
}

function Get-CloudflaredCredentialsPath {
  param(
    [Parameter(Mandatory = $true)] [string] $TunnelId
  )

  return Join-Path (Get-CloudflaredHome) "$TunnelId.json"
}

function Get-FirstUuidFromText {
  param(
    [Parameter(Mandatory = $false)] [string] $Text
  )

  $match = [regex]::Match($Text, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
  if ($match.Success) {
    return $match.Value.ToLowerInvariant()
  }

  return ''
}

function Invoke-CloudflaredCapture {
  param(
    [Parameter(Mandatory = $true)] [string[]] $Arguments,
    [Parameter(Mandatory = $false)] [string] $LogFile = 'logs\cloudflared-setup.log',
    [Parameter(Mandatory = $false)] [int] $TimeoutSeconds = 300,
    [Parameter(Mandatory = $false)] [switch] $AllowNonZero,
    [Parameter(Mandatory = $false)] [switch] $SuppressNonZeroWarning
  )

  $cloudflaredCommand = Get-RequiredCommand 'cloudflared'
  $display = "$($cloudflaredCommand.Source) $($Arguments -join ' ')"
  Write-ProjectLog "Running: $display" $LogFile
  Write-Host "[cloudflared] $display"

  $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("html-server-cloudflared-{0}" -f ([Guid]::NewGuid().ToString('N')))
  $stdoutPath = "$tempBase.out"
  $stderrPath = "$tempBase.err"
  $stdoutPosition = 0L
  $stderrPosition = 0L
  $stdoutStream = $null
  $stderrStream = $null
  $process = $null
  $captured = New-Object System.Collections.Generic.List[string]
  $startedAt = Get-Date

  try {
    $stdoutStream = New-Object System.IO.FileStream($stdoutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    $stderrStream = New-Object System.IO.FileStream($stderrPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $cloudflaredCommand.Source
    $startInfo.Arguments = Join-CommandArguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void] $process.Start()
    $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
    $stderrCopy = $process.StandardError.BaseStream.CopyToAsync($stderrStream)

    while (-not $process.HasExited) {
      $stdout = Read-NewFileContent $stdoutPath ([ref] $stdoutPosition)
      $stderr = Read-NewFileContent $stderrPath ([ref] $stderrPosition)

      if ($stdout.Length -gt 0) {
        $captured.Add($stdout) | Out-Null
        Write-LiveCommandOutput $stdout 'cloudflared' $LogFile
      }

      if ($stderr.Length -gt 0) {
        $captured.Add($stderr) | Out-Null
        Write-LiveCommandOutput $stderr 'cloudflared' $LogFile
      }

      if ($TimeoutSeconds -gt 0 -and ((Get-Date) - $startedAt).TotalSeconds -ge $TimeoutSeconds) {
        try {
          Stop-ProcessTree -ProcessId $process.Id
        } catch {
          Write-ProjectLog "Failed to stop timed-out cloudflared process $($process.Id): $($_.Exception.Message)" $LogFile
        }

        throw "cloudflared command timed out after ${TimeoutSeconds}s: $display"
      }

      Start-Sleep -Milliseconds 500
      $process.Refresh()
    }

    $process.WaitForExit()
    if ($null -ne $stdoutCopy) {
      [void] $stdoutCopy.Wait(2000)
    }
    if ($null -ne $stderrCopy) {
      [void] $stderrCopy.Wait(2000)
    }

    Start-Sleep -Milliseconds 100
    if ($null -ne $stdoutStream) {
      $stdoutStream.Flush()
      $stdoutStream.Dispose()
      $stdoutStream = $null
    }
    if ($null -ne $stderrStream) {
      $stderrStream.Flush()
      $stderrStream.Dispose()
      $stderrStream = $null
    }

    $stdout = Read-NewFileContent $stdoutPath ([ref] $stdoutPosition)
    $stderr = Read-NewFileContent $stderrPath ([ref] $stderrPosition)
    if ($stdout.Length -gt 0) {
      $captured.Add($stdout) | Out-Null
      Write-LiveCommandOutput $stdout 'cloudflared' $LogFile
    }
    if ($stderr.Length -gt 0) {
      $captured.Add($stderr) | Out-Null
      Write-LiveCommandOutput $stderr 'cloudflared' $LogFile
    }

    $exitCode = $process.ExitCode
    $script:LastCloudflaredExitCode = $exitCode
    if ($exitCode -ne 0) {
      $message = "cloudflared command failed with exit code ${exitCode}: $($Arguments -join ' ')"
      Write-ProjectLog $message $LogFile
      if (-not $AllowNonZero) {
        throw $message
      }

      if (-not $SuppressNonZeroWarning) {
        Write-Warning $message
      }
    }

    Write-ProjectLog "Command completed: $display" $LogFile
    return ($captured -join "`n")
  } finally {
    if ($null -ne $stdoutStream) {
      $stdoutStream.Dispose()
    }
    if ($null -ne $stderrStream) {
      $stderrStream.Dispose()
    }

    foreach ($tempPath in @($stdoutPath, $stderrPath)) {
      if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Get-ServerPidFile {
  return Join-Path (Get-ProjectRoot) 'logs\server.pid'
}

function Get-ServerProcess {
  $pidFile = Get-ServerPidFile
  if (-not (Test-Path -LiteralPath $pidFile)) {
    return $null
  }

  $pidText = (Get-Content -LiteralPath $pidFile -Raw).Trim()
  $serverPid = 0
  if (-not [int]::TryParse($pidText, [ref] $serverPid)) {
    return $null
  }

  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $serverPid" -ErrorAction SilentlyContinue
  if ($null -eq $process) {
    return $null
  }

  if ($process.CommandLine -like '*server.js*') {
    return $process
  }

  return $null
}

function Get-CloudflaredPidFile {
  return Join-Path (Get-ProjectRoot) 'logs\cloudflared.pid'
}

function Get-CloudflaredProcess {
  $pidFile = Get-CloudflaredPidFile
  if (-not (Test-Path -LiteralPath $pidFile)) {
    return $null
  }

  $pidText = (Get-Content -LiteralPath $pidFile -Raw).Trim()
  $cloudflaredPid = 0
  if (-not [int]::TryParse($pidText, [ref] $cloudflaredPid)) {
    return $null
  }

  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $cloudflaredPid" -ErrorAction SilentlyContinue
  if ($null -eq $process) {
    return $null
  }

  if ($process.ProcessName -like 'cloudflared*' -or $process.CommandLine -like '*cloudflared*') {
    return $process
  }

  return $null
}

function Test-CloudflaredTunnelActive {
  param(
    [Parameter(Mandatory = $false)] $Config = $null,
    [Parameter(Mandatory = $false)] [int] $TimeoutSeconds = 45
  )

  if ($null -eq $Config) {
    $Config = Get-SiteConfig
  }

  $cloudflared = Get-PropertyValue $Config 'cloudflared' $null
  $tunnelId = Get-PropertyValue $cloudflared 'tunnelId' ''
  if (Test-IsPlaceholder $tunnelId) {
    return [pscustomobject]@{
      Ok = $false
      Message = 'cloudflared.tunnelId is empty or still a placeholder.'
      Output = ''
    }
  }

  try {
    $output = Invoke-CloudflaredCapture `
      -Arguments @('tunnel', 'info', $tunnelId) `
      -TimeoutSeconds $TimeoutSeconds `
      -AllowNonZero `
      -SuppressNonZeroWarning

    if ($script:LastCloudflaredExitCode -ne 0) {
      return [pscustomobject]@{
        Ok = $false
        Message = "cloudflared tunnel info failed with exit code $script:LastCloudflaredExitCode."
        Output = $output
      }
    }

    if ($output -match 'does not have any active connection') {
      return [pscustomobject]@{
        Ok = $false
        Message = 'Cloudflare reports that the tunnel has no active connection.'
        Output = $output
      }
    }

    return [pscustomobject]@{
      Ok = $true
      Message = 'Cloudflare tunnel has at least one active connection.'
      Output = $output
    }
  } catch {
    return [pscustomobject]@{
      Ok = $false
      Message = "Unable to check Cloudflare tunnel active connection: $($_.Exception.Message)"
      Output = ''
    }
  }
}

function Get-TaskExists {
  param(
    [Parameter(Mandatory = $true)] [string] $TaskName
  )

  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  return $null -ne $task
}

function Get-ConfiguredTaskNames {
  param(
    [Parameter(Mandatory = $false)] $Config = $null
  )

  if ($null -eq $Config) {
    $Config = Get-SiteConfig
  }

  $serverName = Get-PropertyValue $Config.server 'name' 'LocalHtmlServer'
  return @(
    "$serverName-Start",
    "$serverName-GitPull",
    "$serverName-Cloudflared"
  )
}

function Test-CommandExists {
  param(
    [Parameter(Mandatory = $true)] [string] $Name
  )

  if ($Name -eq 'cloudflared') {
    return $null -ne (Find-CloudflaredExecutable)
  }

  return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-IsPlaceholder {
  param(
    [Parameter(Mandatory = $false)] [string] $Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $true
  }

  return $Value -like '*<*' -or $Value -like 'example.*' -or $Value -eq 'html.example.com'
}

function Stop-ProcessTree {
  param(
    [Parameter(Mandatory = $true)] [int] $ProcessId
  )

  $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)
  foreach ($child in $children) {
    Stop-ProcessTree -ProcessId $child.ProcessId
  }

  Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Get-RepositoryGitProcesses {
  param(
    [Parameter(Mandatory = $true)] [string] $RepoPath
  )

  $resolvedPath = $RepoPath
  if (Test-Path -LiteralPath $RepoPath) {
    $resolvedPath = (Resolve-Path -LiteralPath $RepoPath).Path
  }

  return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -like 'git*' -and $_.CommandLine -like "*$resolvedPath*"
  })
}

function Invoke-CheckedCommand {
  param(
    [Parameter(Mandatory = $true)] [string] $FilePath,
    [Parameter(Mandatory = $false)] [string[]] $Arguments = @(),
    [Parameter(Mandatory = $false)] [string] $LogFile = 'logs\operations.log'
  )

  $display = "$FilePath $($Arguments -join ' ')"
  Write-ProjectLog "Running: $display" $LogFile
  $output = & $FilePath @Arguments 2>&1
  $exitCode = $LASTEXITCODE

  foreach ($line in $output) {
    if (-not [string]::IsNullOrEmpty([string] $line)) {
      Write-ProjectLog ([string] $line) $LogFile
    }
  }

  if ($exitCode -ne 0) {
    throw "Command failed with exit code ${exitCode}: $display"
  }

  return $output
}

function Read-NewFileContent {
  param(
    [Parameter(Mandatory = $true)] [string] $PathValue,
    [Parameter(Mandatory = $true)] [ref] $Position
  )

  if (-not (Test-Path -LiteralPath $PathValue)) {
    return ''
  }

  $stream = $null
  $reader = $null
  try {
    $stream = [System.IO.File]::Open($PathValue, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    if ($Position.Value -gt $stream.Length) {
      $Position.Value = 0
    }

    [void] $stream.Seek($Position.Value, [System.IO.SeekOrigin]::Begin)
    $reader = New-Object System.IO.StreamReader($stream)
    $text = $reader.ReadToEnd()
    $Position.Value = $stream.Position
    return $text
  } finally {
    if ($null -ne $reader) {
      $reader.Dispose()
    } elseif ($null -ne $stream) {
      $stream.Dispose()
    }
  }
}

function Write-LiveCommandOutput {
  param(
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Text,
    [Parameter(Mandatory = $true)] [string] $Prefix,
    [Parameter(Mandatory = $false)] [string] $LogFile = 'logs\operations.log'
  )

  if ([string]::IsNullOrEmpty($Text)) {
    return
  }

  $normalized = $Text -replace "`r", "`n"
  foreach ($line in ($normalized -split "`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $message = "[$Prefix] $line"
    Write-Host $message
    Write-ProjectLog $message $LogFile
  }
}

function Join-CommandArguments {
  param(
    [Parameter(Mandatory = $false)] [string[]] $Arguments = @()
  )

  $quoted = foreach ($argument in $Arguments) {
    if ($null -eq $argument) {
      '""'
    } elseif ($argument -match '^[A-Za-z0-9_./:=+@%,-]+$') {
      $argument
    } else {
      '"' + ($argument -replace '"', '\"') + '"'
    }
  }

  return ($quoted -join ' ')
}

function Invoke-CommandWithProgress {
  param(
    [Parameter(Mandatory = $true)] [string] $FilePath,
    [Parameter(Mandatory = $false)] [string[]] $Arguments = @(),
    [Parameter(Mandatory = $false)] [string] $LogFile = 'logs\operations.log',
    [Parameter(Mandatory = $false)] [string] $Label = 'cmd',
    [Parameter(Mandatory = $false)] [int] $StallTimeoutSeconds = 120,
    [Parameter(Mandatory = $false)] [int] $MaxRetries = 1,
    [Parameter(Mandatory = $false)] [int] $RetryDelaySeconds = 5,
    [Parameter(Mandatory = $false)] [string] $WorkingDirectory = ''
  )

  $attempt = 0
  $maxAttempts = [Math]::Max(1, $MaxRetries + 1)
  $display = "$FilePath $($Arguments -join ' ')"

  while ($attempt -lt $maxAttempts) {
    $attempt += 1
    $suffix = if ($maxAttempts -gt 1) { " attempt $attempt/$maxAttempts" } else { '' }
    Write-Host "[$Label] running${suffix}: $display"
    Write-ProjectLog "Running${suffix}: $display" $LogFile

    $tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("html-server-{0}-{1}" -f ([Guid]::NewGuid().ToString('N')), $Label)
    $stdoutPath = "$tempBase.out"
    $stderrPath = "$tempBase.err"
    $stdoutPosition = 0L
    $stderrPosition = 0L
    $process = $null
    $lastActivity = Get-Date

    try {
      $stdoutStream = New-Object System.IO.FileStream($stdoutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
      $stderrStream = New-Object System.IO.FileStream($stderrPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
      $startInfo = New-Object System.Diagnostics.ProcessStartInfo
      $startInfo.FileName = $FilePath
      $startInfo.Arguments = Join-CommandArguments $Arguments
      $startInfo.UseShellExecute = $false
      $startInfo.RedirectStandardOutput = $true
      $startInfo.RedirectStandardError = $true
      $startInfo.CreateNoWindow = $true

      if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
      }

      $process = New-Object System.Diagnostics.Process
      $process.StartInfo = $startInfo
      [void] $process.Start()
      $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
      $stderrCopy = $process.StandardError.BaseStream.CopyToAsync($stderrStream)

      while (-not $process.HasExited) {
        $stdout = Read-NewFileContent $stdoutPath ([ref] $stdoutPosition)
        $stderr = Read-NewFileContent $stderrPath ([ref] $stderrPosition)

        if ($stdout.Length -gt 0) {
          $lastActivity = Get-Date
          Write-LiveCommandOutput $stdout $Label $LogFile
        }

        if ($stderr.Length -gt 0) {
          $lastActivity = Get-Date
          Write-LiveCommandOutput $stderr $Label $LogFile
        }

        if (((Get-Date) - $lastActivity).TotalSeconds -ge $StallTimeoutSeconds) {
          try {
            Stop-ProcessTree -ProcessId $process.Id
          } catch {
            Write-ProjectLog "Failed to stop stalled process $($process.Id): $($_.Exception.Message)" $LogFile
          }

          throw "No output from '$display' for ${StallTimeoutSeconds}s. The process was stopped as stalled."
        }

        Start-Sleep -Milliseconds 500
        $process.Refresh()
      }

      $process.WaitForExit()
      if ($null -ne $stdoutCopy) {
        [void] $stdoutCopy.Wait(2000)
      }
      if ($null -ne $stderrCopy) {
        [void] $stderrCopy.Wait(2000)
      }
      Start-Sleep -Milliseconds 100
      if ($null -ne $stdoutStream) {
        $stdoutStream.Flush()
        $stdoutStream.Dispose()
        $stdoutStream = $null
      }
      if ($null -ne $stderrStream) {
        $stderrStream.Flush()
        $stderrStream.Dispose()
        $stderrStream = $null
      }
      $process.Refresh()
      $stdout = Read-NewFileContent $stdoutPath ([ref] $stdoutPosition)
      $stderr = Read-NewFileContent $stderrPath ([ref] $stderrPosition)
      Write-LiveCommandOutput $stdout $Label $LogFile
      Write-LiveCommandOutput $stderr $Label $LogFile

      $exitCode = $process.ExitCode
      if ($exitCode -ne 0) {
        throw "Command failed with exit code ${exitCode}: $display"
      }

      Write-ProjectLog "Command completed: $display" $LogFile
      return
    } catch {
      $message = $_.Exception.Message
      Write-Warning "[$Label] $message"
      Write-ProjectLog "Command failed: $message" $LogFile

      if ($attempt -ge $maxAttempts) {
        throw
      }

      Write-Warning "[$Label] Retrying in ${RetryDelaySeconds}s..."
      Start-Sleep -Seconds $RetryDelaySeconds
    } finally {
      if ($null -ne $stdoutStream) {
        $stdoutStream.Dispose()
      }
      if ($null -ne $stderrStream) {
        $stderrStream.Dispose()
      }
      foreach ($tempPath in @($stdoutPath, $stderrPath)) {
        if (Test-Path -LiteralPath $tempPath) {
          Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
      }
    }
  }
}

function Update-GitRepository {
  param(
    [Parameter(Mandatory = $true)] [string] $Name,
    [Parameter(Mandatory = $false)] $RepositoryConfig,
    [Parameter(Mandatory = $true)] [string] $DefaultLocalPath,
    [Parameter(Mandatory = $false)] [string] $LogFile = 'logs\git-update.log',
    [Parameter(Mandatory = $false)] [switch] $ShowProgress,
    [Parameter(Mandatory = $false)] [int] $StallTimeoutSeconds = 120,
    [Parameter(Mandatory = $false)] [int] $MaxRetries = 1
  )

  $enabled = Get-PropertyValue $RepositoryConfig 'enabled' $true
  if (-not $enabled) {
    Write-ProjectLog "$Name Git update skipped because enabled is false." $LogFile
    return [pscustomobject]@{
      Name = $Name
      Path = ''
      Changed = $false
      Skipped = $true
      Message = 'disabled'
    }
  }

  $git = Get-RequiredCommand 'git'
  $localPathValue = Get-PropertyValue $RepositoryConfig 'localPath' $DefaultLocalPath
  $repoPath = Resolve-ProjectPath $localPathValue
  $url = Get-PropertyValue $RepositoryConfig 'url' ''
  $remote = Get-PropertyValue $RepositoryConfig 'remote' 'origin'
  $branch = Get-PropertyValue $RepositoryConfig 'branch' ''
  $cloneIfMissing = Get-PropertyValue $RepositoryConfig 'cloneIfMissing' $false

  function Invoke-GitStep {
    param(
      [Parameter(Mandatory = $true)] [string[]] $Arguments,
      [Parameter(Mandatory = $true)] [string] $Label,
      [Parameter(Mandatory = $false)] [int] $StepRetries = $MaxRetries
    )

    if ($ShowProgress) {
      Invoke-CommandWithProgress `
        -FilePath $git.Source `
        -Arguments $Arguments `
        -LogFile $LogFile `
        -Label $Label `
        -StallTimeoutSeconds $StallTimeoutSeconds `
        -MaxRetries $StepRetries
    } else {
      Invoke-CheckedCommand $git.Source $Arguments $LogFile | Out-Null
    }
  }

  if (-not (Test-Path -LiteralPath $repoPath)) {
    if ($url -ne '' -and $cloneIfMissing) {
      Ensure-Directory (Split-Path -Parent $repoPath)
      $cloneArgs = @('clone')
      if ($ShowProgress) {
        $cloneArgs += '--progress'
      }
      if ($branch -ne '') {
        $cloneArgs += @('--branch', $branch)
      }
      $cloneArgs += @($url, $repoPath)

      $cloneAttempt = 0
      $cloneMaxAttempts = [Math]::Max(1, $MaxRetries + 1)
      while ($cloneAttempt -lt $cloneMaxAttempts) {
        $cloneAttempt += 1
        try {
          Invoke-GitStep $cloneArgs "$Name clone" 0
          break
        } catch {
          if ($cloneAttempt -ge $cloneMaxAttempts) {
            throw
          }

          if (Test-Path -LiteralPath $repoPath) {
            $backupPath = "$repoPath.failed-$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$cloneAttempt"
            Move-Item -LiteralPath $repoPath -Destination $backupPath -Force
            Write-Warning "$Name clone left a partial directory. Moved it to: $backupPath"
            Write-ProjectLog "$Name clone partial directory moved to: $backupPath" $LogFile
          }

          Write-Warning "$Name clone retrying in 5s..."
          Start-Sleep -Seconds 5
        }
      }

      return [pscustomobject]@{
        Name = $Name
        Path = $repoPath
        Changed = $true
        Skipped = $false
        Message = 'cloned'
      }
    }

    Write-ProjectLog "$Name Git update skipped because repository path does not exist: $repoPath" $LogFile
    return [pscustomobject]@{
      Name = $Name
      Path = $repoPath
      Changed = $false
      Skipped = $true
      Message = 'missing'
    }
  }

  if (-not (Test-Path -LiteralPath (Join-Path $repoPath '.git'))) {
    Write-ProjectLog "$Name Git update skipped because path is not a Git repository: $repoPath" $LogFile
    return [pscustomobject]@{
      Name = $Name
      Path = $repoPath
      Changed = $false
      Skipped = $true
      Message = 'not-a-git-repo'
    }
  }

  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    & $git.Source -C $repoPath rev-parse --verify HEAD 2>$null | Out-Null
    $headExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }

  if ($headExitCode -ne 0) {
    if ($url -ne '' -and $cloneIfMissing) {
      $activeRepoGitProcesses = @(Get-RepositoryGitProcesses $repoPath)
      if ($activeRepoGitProcesses.Count -gt 0) {
        $details = ($activeRepoGitProcesses | ForEach-Object {
          "PID $($_.ProcessId): $($_.CommandLine)"
        }) -join '; '
        throw "${Name}: repository appears partially cloned, but Git is still using it. Wait for the process to finish or stop it, then retry. $details"
      }

      $backupPath = "$repoPath.failed-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
      Move-Item -LiteralPath $repoPath -Destination $backupPath -Force
      Write-Warning "$Name repository has no valid HEAD. Moved partial repository to: $backupPath"
      Write-ProjectLog "$Name invalid repository moved to: $backupPath" $LogFile
      return Update-GitRepository `
        -Name $Name `
        -RepositoryConfig $RepositoryConfig `
        -DefaultLocalPath $DefaultLocalPath `
        -LogFile $LogFile `
        -ShowProgress:$ShowProgress `
        -StallTimeoutSeconds $StallTimeoutSeconds `
        -MaxRetries $MaxRetries
    }

    throw "${Name}: repository exists but has no valid HEAD commit: $repoPath"
  }

  $remoteList = @(& $git.Source -C $repoPath remote 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "${Name}: failed to read Git remotes."
  }

  if (-not ($remoteList -contains $remote)) {
    if ($url -ne '') {
      Invoke-GitStep @('-C', $repoPath, 'remote', 'add', $remote, $url) "$Name remote" 0
    } else {
      Write-ProjectLog "$Name Git update skipped because remote '$remote' is not configured." $LogFile
      return [pscustomobject]@{
        Name = $Name
        Path = $repoPath
        Changed = $false
        Skipped = $true
        Message = "remote-missing:$remote"
      }
    }
  }

  $before = (& $git.Source -C $repoPath rev-parse HEAD 2>$null)
  if ($LASTEXITCODE -ne 0) {
    throw "${Name}: unable to read current Git commit."
  }

  $fetchArgs = @('-C', $repoPath, 'fetch')
  if ($ShowProgress) {
    $fetchArgs += '--progress'
  }
  $fetchArgs += @($remote, '--prune')
  Invoke-GitStep $fetchArgs "$Name fetch"

  if ($branch -ne '') {
    $pullArgs = @('-C', $repoPath, 'pull')
    if ($ShowProgress) {
      $pullArgs += '--progress'
    }
    $pullArgs += @('--ff-only', $remote, $branch)
    Invoke-GitStep $pullArgs "$Name pull"
  } else {
    $pullArgs = @('-C', $repoPath, 'pull')
    if ($ShowProgress) {
      $pullArgs += '--progress'
    }
    $pullArgs += '--ff-only'
    Invoke-GitStep $pullArgs "$Name pull"
  }

  $after = (& $git.Source -C $repoPath rev-parse HEAD 2>$null)
  if ($LASTEXITCODE -ne 0) {
    throw "${Name}: unable to read updated Git commit."
  }

  $changed = $before -ne $after
  if ($changed) {
    Write-ProjectLog "$Name updated from $before to $after" $LogFile
  } else {
    Write-ProjectLog "$Name has no Git changes. Current commit: $after" $LogFile
  }

  return [pscustomobject]@{
    Name = $Name
    Path = $repoPath
    Changed = $changed
    Skipped = $false
    Message = $after
  }
}
