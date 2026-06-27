[CmdletBinding()]
param()

& "$PSScriptRoot\stop-server.ps1"
& "$PSScriptRoot\start-server.ps1" -Background
