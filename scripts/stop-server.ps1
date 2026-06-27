[CmdletBinding()]
param(
  [int] $TimeoutSeconds = 8
)

. "$PSScriptRoot\lib.ps1"

$process = Get-ServerProcess
if ($null -eq $process) {
  Write-Host 'Server is not running.'
  exit 0
}

Write-Host "Stopping server. PID: $($process.ProcessId)"
Stop-Process -Id $process.ProcessId -ErrorAction Stop

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 250
  if ($null -eq (Get-CimInstance Win32_Process -Filter "ProcessId = $($process.ProcessId)" -ErrorAction SilentlyContinue)) {
    break
  }
}

if ($null -ne (Get-CimInstance Win32_Process -Filter "ProcessId = $($process.ProcessId)" -ErrorAction SilentlyContinue)) {
  throw "Server did not stop within ${TimeoutSeconds}s."
}

$pidFile = Get-ServerPidFile
if (Test-Path -LiteralPath $pidFile) {
  Remove-Item -LiteralPath $pidFile -Force
}

Write-Host 'Server stopped.'
